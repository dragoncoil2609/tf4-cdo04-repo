import os
import json
import time
import boto3
import requests
from botocore.exceptions import ClientError
from requests_aws4auth import AWS4Auth

# Cấu hình biến môi trường
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")
AMP_QUERY_ENDPOINT = os.getenv("AMP_QUERY_ENDPOINT")  # e.g., https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx
AI_ENGINE_ENDPOINT = os.getenv("AI_ENGINE_ENDPOINT", "http://ai-engine.cdo-services/v1/predict")
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
    Truy vấn dữ liệu metric lịch sử từ Amazon Managed Prometheus (AMP)
    """
    end_time = int(time.time())
    start_time = end_time - (duration_minutes * 60)
    
    # Query PromQL lọc theo Tenant và Service
    query = f'http_requests_total{{tenant_id="{tenant_id}", service="{service_name}"}}'
    
    url = f"{AMP_QUERY_ENDPOINT}/api/v1/query_range"
    params = {
        "query": query,
        "start": start_time,
        "end": end_time,
        "step": "60s"  # Lấy mẫu 1 phút/lần
    }
    
    try:
        response = requests.get(url, auth=aws_auth, params=params, timeout=10)
        if response.status_code == 200:
            return response.json().get("data", {}).get("result", [])
        else:
            print(f"Lỗi truy vấn AMP: HTTP {response.status_code} - {response.text}")
            return None
    except Exception as e:
        print(f"Không thể kết nối AMP: {str(e)}")
        return None

def get_static_threshold_fallback(tenant_id, service_name):
    """
    Lấy static threshold từ DynamoDB policy table để fallback
    """
    try:
        response = policy_table.get_item(Key={"tenant_id": tenant_id, "service_name": service_name})
        if "Item" in response:
            return response["Item"].get("static_threshold", 85.0)  # Default 85%
    except Exception as e:
        print(f"Lỗi đọc DynamoDB policy table: {str(e)}")
    return 85.0

def save_audit_log(prediction_id, tenant_id, service_name, decision, prediction_source, score):
    """
    Lưu quyết định dự báo vào DynamoDB Audit Logs Table
    """
    item = {
        "prediction_id": prediction_id,
        "tenant_id": tenant_id,
        "service_name": service_name,
        "timestamp": int(time.time()),
        "decision": decision,
        "prediction_source": prediction_source,
        "score": str(score)
    }
    try:
        audit_table.put_item(Item=item)
        print(f"Đã lưu audit log cho {prediction_id} thành công.")
    except Exception as e:
        print(f"Lỗi ghi DynamoDB audit log: {str(e)}")

def process_job(job_data):
    """
    Xử lý một bản tin dự báo từ SQS
    """
    # 1. Parse các trường dữ liệu bắt buộc (CPOA-61)
    prediction_id = job_data.get("prediction_id")
    tenant_id = job_data.get("tenant_id")
    service_name = job_data.get("service_name")
    lookback_window_minutes = job_data.get("lookback_window_minutes")
    correlation_id = job_data.get("correlation_id", prediction_id)
    
    print(f"Nhận job: correlation_id={correlation_id}, tenant_id={tenant_id}, service={service_name}, lookback={lookback_window_minutes}")
    
    # 2. Validate lookback_window_minutes = 120 (CPOA-61)
    if lookback_window_minutes is None:
        print("Cảnh báo: lookback_window_minutes trống. Thiết lập về 120.")
        lookback_window_minutes = 120
    else:
        try:
            lookback_val = int(lookback_window_minutes)
            if lookback_val != 120:
                print(f"Cảnh báo: lookback_window_minutes là {lookback_val}, điều chỉnh thành 120 theo yêu cầu.")
                lookback_window_minutes = 120
        except ValueError:
            print("Lỗi định dạng lookback_window_minutes. Sử dụng 120.")
            lookback_window_minutes = 120
            
    # 3. Query metrics từ AMP
    metrics = query_amp_metrics(tenant_id, service_name, duration_minutes=lookback_window_minutes)
    
    # 2. Gọi AI Engine để lấy kết quả (Fail-Open Fallback)
    decision = "UNKNOWN"
    score = 0.0
    prediction_source = "AI_ENGINE"
    
    if metrics:
        try:
            payload = {"tenant_id": tenant_id, "service_name": service_name, "metrics": metrics}
            response = requests.post(AI_ENGINE_ENDPOINT, json=payload, timeout=5)
            
            if response.status_code == 200:
                result = response.json()
                decision = result.get("decision")
                score = result.get("score", 0.0)
            else:
                print(f"AI Engine trả về lỗi {response.status_code}. Kích hoạt Fallback.")
                prediction_source = "STATIC_THRESHOLD_FALLBACK"
        except Exception as e:
            print(f"AI Engine không phản hồi: {str(e)}. Kích hoạt Fallback.")
            prediction_source = "STATIC_THRESHOLD_FALLBACK"
    else:
        print("Không lấy được dữ liệu metrics từ AMP. Kích hoạt Fallback.")
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        
    # 3. Thực hiện tính toán fallback bằng static threshold nếu cần
    if prediction_source == "STATIC_THRESHOLD_FALLBACK":
        threshold = get_static_threshold_fallback(tenant_id, service_name)
        score = threshold
        decision = "SCALE_UP" if score > 80.0 else "KEEP_ALIVE"
        
    # 4. Lưu Audit Log
    save_audit_log(prediction_id, tenant_id, service_name, decision, prediction_source, score)

def main():
    print("Worker đã khởi động và đang đợi tin nhắn từ SQS...")
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
            print(f"Lỗi SQS Client: {str(e)}")
            time.sleep(5)
        except Exception as e:
            print(f"Lỗi không xác định: {str(e)}")
            time.sleep(5)

if __name__ == "__main__":
    main()
