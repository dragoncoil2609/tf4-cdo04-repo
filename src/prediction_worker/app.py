import os
import json
import time
from datetime import datetime, timezone

import boto3
import requests
from botocore.exceptions import ClientError
from requests_aws4auth import AWS4Auth

# Cấu hình biến môi trường
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")
AMP_QUERY_ENDPOINT = os.getenv("AMP_QUERY_ENDPOINT")  # e.g., https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx
AI_ENGINE_ENDPOINT = os.getenv("AI_ENGINE_ENDPOINT", "http://ai-engine.cdo-services/v1/predict")
AI_TIMEOUT_SECONDS = float(os.getenv("AI_TIMEOUT_SECONDS", "2"))
DYNAMODB_AUDIT_TABLE = os.getenv("DYNAMODB_AUDIT_TABLE", "cdo04-audit-logs")
DYNAMODB_POLICY_TABLE = os.getenv("DYNAMODB_POLICY_TABLE", "cdo04-service-policies")

# Khởi tạo AWS Clients
sqs = boto3.client("sqs", region_name=AWS_REGION)
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
audit_table = dynamodb.Table(DYNAMODB_AUDIT_TABLE)
policy_table = dynamodb.Table(DYNAMODB_POLICY_TABLE)

# Cấu hình SigV4 để ký request khi gọi Prometheus AMP
credentials = boto3.Session().get_credentials()
aws_auth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    AWS_REGION,
    "aps",
    session_token=credentials.token
)

def query_amp_metrics(tenant_id, service_name, duration_minutes=120):
    """
    TASK: CPOA-101 | CDO-W12-056 - AMP Query Optimization
    OWNER: Tạ Hoàng Huy
    
    Truy vấn tuần tự 7 tín hiệu cốt lõi từ Amazon Managed Prometheus (AMP).
    Ép buộc filter nhãn tường minh tenant_id và service_id để bảo vệ quota,
    tránh quét diện rộng gây bùng nổ cardinality.
    """
    end_time = int(time.time())
    start_time = end_time - (duration_minutes * 60)

    signals = [
        "cpu_usage_percent",
        "memory_usage_percent",
        "active_connections",
        "db_connection_pool_pct",
        "queue_depth",
        "cache_hit_rate_pct",
        "api_latency_ms"
    ]

    combined_metrics = {}
    amp_base_url = AMP_QUERY_ENDPOINT.rstrip("/").removesuffix("/api/v1/query")
    url = f"{amp_base_url}/api/v1/query_range"

    for signal in signals:
        # Bảo vệ quota bằng cách lọc tường minh tenant_id và service_id
        query = f'{signal}{{tenant_id="{tenant_id}", service_id="{service_name}"}}'
        params = {
            "query": query,
            "start": start_time,
            "end": end_time,
            "step": "60s"
        }

        try:
            print(f"Executing PromQL query: {query}", flush=True)
            response = requests.get(url, auth=aws_auth, params=params, timeout=10)
            if response.status_code == 200:
                result = response.json().get("data", {}).get("result", [])
                combined_metrics[signal] = result
            else:
                print(f"Lỗi truy vấn AMP cho {signal}: HTTP {response.status_code} - {response.text}", flush=True)
        except Exception as e:
            print(f"Không thể kết nối AMP để truy vấn {signal}: {str(e)}", flush=True)

    return combined_metrics

def get_static_threshold_fallback(tenant_id, service_name):
    """
    Lấy static threshold từ DynamoDB policy table để fallback
    """
    try:
        response = policy_table.get_item(Key={"tenant_id": tenant_id, "service_name": service_name})
        if "Item" in response:
            return response["Item"].get("static_threshold", 85.0)  # Default 85%
    except Exception as e:
        print(f"Lỗi đọc DynamoDB policy table: {str(e)}", flush=True)
    return 85.0

def save_audit_log(prediction_id, tenant_id, service_name, decision, prediction_source, score):
    """
    TASK: CPOA-103 | CDO-W12-058 - Retention policies
    OWNER: Tạ Hoàng Huy

    Lưu quyết định dự báo vào DynamoDB Audit Logs Table kèm TTL 90 ngày.
    Ném lỗi nếu ghi thất bại để tránh xóa tin nhắn SQS trước khi audit thành công.
    """
    now = datetime.now(timezone.utc)
    now_epoch = int(now.timestamp())
    retention_seconds = 90 * 24 * 60 * 60
    expires_at_epoch = now_epoch + retention_seconds

    item = {
        "tenant_id": tenant_id,
        "service_time": now.isoformat(),
        "prediction_status": "complete",
        "prediction_timestamp": now.isoformat(),
        "prediction_id": prediction_id,
        "service_name": service_name,
        "timestamp": now_epoch,
        "decision": decision,
        "prediction_source": prediction_source,
        "score": str(score),
        "expires_at_epoch": expires_at_epoch # Đảm bảo đúng chuẩn TTL cột
    }
    try:
        audit_table.put_item(Item=item)
        print(f"Successfully saved audit log for prediction: {prediction_id}", flush=True)
    except Exception as e:
        print(f"Lỗi ghi DynamoDB audit log: {str(e)}", flush=True)
        raise e  # Ném lỗi để chặn xóa tin nhắn SQS khi lưu log thất bại

def process_job(job_data):
    """
    Xử lý một bản tin dự báo từ SQS
    """
    # 1. Parse các trường dữ liệu bắt buộc từ SQS Body
    prediction_id = job_data.get("correlation_id") or job_data.get("prediction_id")
    tenant_id = job_data.get("tenant_id")
    service_name = job_data.get("service_id") or job_data.get("service_name")
    lookback_window_minutes = job_data.get("lookback_window_minutes")
    
    if not prediction_id or not tenant_id or not service_name:
        raise ValueError("Thiếu trường thông tin bắt buộc: correlation_id/prediction_id, tenant_id, service_id/service_name")

    # 2. Xác thực trường lookback_window_minutes bắt buộc bằng 120
    if lookback_window_minutes is not None:
        try:
            lookback_val = int(lookback_window_minutes)
        except ValueError:
            raise ValueError(f"lookback_window_minutes không đúng định dạng số: {lookback_window_minutes}")
        if lookback_val != 120:
            raise ValueError(f"Xác thực thất bại: lookback_window_minutes phải bằng 120 (nhận được: {lookback_val})")
    else:
        # Nếu không truyền, mặc định gán 120 theo thiết kế
        lookback_val = 120

    print(f"Đang xử lý job {prediction_id} cho tenant {tenant_id} với lookback {lookback_val} phút...", flush=True)
    
    # 3. Query metrics từ AMP
    metrics = query_amp_metrics(tenant_id, service_name, duration_minutes=lookback_val)
    
    # 2. Gọi AI Engine để lấy kết quả (Fail-Open Fallback)
    decision = "UNKNOWN"
    score = 0.0
    prediction_source = "AI_ENGINE"
    
    if metrics:
        try:
            payload = {"tenant_id": tenant_id, "service_name": service_name, "metrics": metrics}
            response = requests.post(AI_ENGINE_ENDPOINT, json=payload, timeout=AI_TIMEOUT_SECONDS)
            
            if response.status_code == 200:
                result = response.json()
                decision = result.get("decision")
                score = result.get("score", 0.0)
            else:
                print(f"AI Engine trả về lỗi {response.status_code}. Kích hoạt Fallback.", flush=True)
                prediction_source = "STATIC_THRESHOLD_FALLBACK"
        except Exception as e:
            print(f"AI Engine không phản hồi: {str(e)}. Kích hoạt Fallback.", flush=True)
            prediction_source = "STATIC_THRESHOLD_FALLBACK"
    else:
        print("Không lấy được dữ liệu metrics từ AMP. Kích hoạt Fallback.", flush=True)
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        
    # 3. Thực hiện tính toán fallback bằng static threshold nếu cần
    if prediction_source == "STATIC_THRESHOLD_FALLBACK":
        threshold = get_static_threshold_fallback(tenant_id, service_name)
        score = threshold
        decision = "SCALE_UP" if score > 80.0 else "KEEP_ALIVE"
        
    # 4. Lưu Audit Log
    save_audit_log(prediction_id, tenant_id, service_name, decision, prediction_source, score)

def main():
    print("Worker đã khởi động và đang đợi tin nhắn từ SQS...", flush=True)
    while True:
        try:
            # Nhận tin nhắn từ SQS (Long Polling 20 giây)
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20
            )
            
            messages = response.get("Messages", [])
            for message in messages:
                body = json.loads(message["Body"])
                process_job(body)
                
                # Xóa tin nhắn khỏi hàng đợi sau khi xử lý thành công
                sqs.delete_message(
                    QueueUrl=SQS_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"]
                )
        except ClientError as e:
            print(f"Lỗi SQS Client: {str(e)}", flush=True)
            time.sleep(5)
        except Exception as e:
            print(f"Lỗi không xác định: {str(e)}", flush=True)
            time.sleep(5)

if __name__ == "__main__":
    main()
