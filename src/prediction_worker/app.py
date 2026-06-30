import os
import json
import time
from datetime import datetime, timezone
import uuid
from decimal import Decimal

import boto3
import requests
from botocore.exceptions import ClientError
from requests_aws4auth import AWS4Auth

from fallback_engine import (   # THÊM — Phan Minh Tuấn CPOA-71..77
    get_service_policy,
    check_signal_window,
    run_static_fallback,
    call_ai_with_retry,
)

# Cấu hình biến môi trường
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")
AMP_QUERY_ENDPOINT = os.getenv("AMP_QUERY_ENDPOINT")  # e.g., https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx
AI_ENGINE_ENDPOINT = os.getenv("AI_ENGINE_ENDPOINT", "http://ai-engine.cdo-services/v1/predict")
AI_TIMEOUT_SECONDS = float(os.getenv("AI_TIMEOUT_SECONDS", "2"))
DYNAMODB_AUDIT_TABLE = os.getenv("DYNAMODB_AUDIT_TABLE", "cdo04-audit-logs")
DYNAMODB_POLICY_TABLE = os.getenv("DYNAMODB_POLICY_TABLE", "cdo04-service-policies")
ALERT_TOPIC_ARN = os.getenv("ALERT_TOPIC_ARN")

# TASK: CPOA-63 | CDO-W12-022 - Bucket alignment + imputation
# Fill policy theo từng metric: forward_fill (giá trị tồn tại) vs zero_fill (không có = 0)
METRIC_FILL_POLICY = {
    "cpu_usage_percent":      "forward_fill",
    "memory_usage_percent":   "forward_fill",
    "active_connections":     "forward_fill",
    "db_connection_pool_pct": "forward_fill",
    "queue_depth":            "zero_fill",    # không có request = queue rỗng
    "cache_hit_rate_pct":     "forward_fill",
    "api_latency_ms":         "forward_fill",
}
# Nếu tỷ lệ bucket bị thiếu vượt ngưỡng này → không gọi AI, chuyển fallback
MAX_GAP_THRESHOLD = 0.5  # 50%

# Khởi tạo AWS Clients
sqs = boto3.client("sqs", region_name=AWS_REGION)
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
sns = boto3.client("sns", region_name=AWS_REGION)
audit_table = dynamodb.Table(DYNAMODB_AUDIT_TABLE)
policy_table = dynamodb.Table(DYNAMODB_POLICY_TABLE)


def get_aws_auth(service):
    """
    Tạo dynamic AWS4Auth sử dụng current IAM credentials của ECS Task.
    Tránh lỗi hết hạn token khi Task chạy lâu ngày.
    """
    try:
        session = boto3.Session()
        credentials = session.get_credentials()
        if not credentials:
            return None
        frozen_creds = credentials.get_frozen_credentials()
        return AWS4Auth(
            frozen_creds.access_key,
            frozen_creds.secret_key,
            AWS_REGION,
            service,
            session_token=frozen_creds.token
        )
    except Exception as e:
        print(f"Lỗi lấy AWS credentials cho {service}: {str(e)}", flush=True)
        return None


def align_and_impute(raw_result, start_time, end_time, step_seconds=60, fill_policy="forward_fill"):
    """
    TASK: CPOA-63 | CDO-W12-022 - Bucket alignment + imputation
    OWNER: Tạ Hoàng Huy

    Align AMP query_range result thành 1-minute buckets có index liên tục.
    - forward_fill: dùng giá trị gần nhất trước đó (metric tồn tại liên tục)
    - zero_fill:    dùng 0.0 (không có request/queue = 0)

    Returns:
        aligned (dict): {timestamp_int: float} đầy đủ 120 bucket
        gap_ratio (float): tỷ lệ bucket bị thiếu trước khi impute (0.0 – 1.0)
    """
    expected_timestamps = list(range(start_time, end_time + step_seconds, step_seconds))
    total_buckets = len(expected_timestamps)

    # Build actual data map từ AMP values
    actual_data = {}
    for series in raw_result:
        for ts, val in series.get("values", []):
            actual_data[int(ts)] = float(val)

    aligned = {}
    last_known_value = None
    missing_count = 0

    for ts in expected_timestamps:
        if ts in actual_data:
            aligned[ts] = actual_data[ts]
            last_known_value = actual_data[ts]
        else:
            missing_count += 1
            if fill_policy == "forward_fill" and last_known_value is not None:
                aligned[ts] = last_known_value   # giữ giá trị cuối
            else:
                aligned[ts] = 0.0                 # zero-fill hoặc chưa có giá trị nào

    gap_ratio = missing_count / total_buckets if total_buckets > 0 else 1.0
    return aligned, gap_ratio


def query_amp_metrics(tenant_id, service_name, duration_minutes=120):
    """
    TASK: CPOA-101 | CDO-W12-056 - AMP Query Optimization
    TASK: CPOA-63  | CDO-W12-022 - Bucket alignment + imputation
    OWNER: Tạ Hoàng Huy

    Truy vấn tuần tự 7 tín hiệu cốt lõi từ AMP, sau đó align và impute thành
    1-minute buckets theo METRIC_FILL_POLICY.
    Trả về (aligned_metrics, max_gap_ratio, start_time, end_time) — caller quyết định có gọi AI không.
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

    aligned_metrics = {}
    max_gap_ratio = 0.0
    amp_base_url = AMP_QUERY_ENDPOINT.rstrip("/").removesuffix("/api/v1/query")
    url = f"{amp_base_url}/api/v1/query_range"

    # Tạo auth client động cho Prometheus (AMP)
    amp_auth = get_aws_auth("aps")

    for signal in signals:
        # Bảo vệ quota bằng cách lọc tường minh tenant_id và service_id
        query = f'{signal}{{tenant_id="{tenant_id}", service_id="{service_name}"}}'
        params = {
            "query": query,
            "start": start_time,
            "end": end_time,
            "step": "60s"
        }

        raw_result = []
        try:
            print(f"Executing PromQL query: {query}", flush=True)
            response = requests.get(url, auth=amp_auth, params=params, timeout=10)
            if response.status_code == 200:
                raw_result = response.json().get("data", {}).get("result", [])
            else:
                print(f"Lỗi truy vấn AMP cho {signal}: HTTP {response.status_code} - {response.text}", flush=True)
        except Exception as e:
            print(f"Không thể kết nối AMP để truy vấn {signal}: {str(e)}", flush=True)

        # Align và impute bucket theo metric policy
        fill_policy = METRIC_FILL_POLICY.get(signal, "forward_fill")
        aligned, gap_ratio = align_and_impute(raw_result, start_time, end_time, fill_policy=fill_policy)
        aligned_metrics[signal] = aligned
        max_gap_ratio = max(max_gap_ratio, gap_ratio)

        if gap_ratio > 0:
            print(f"Signal '{signal}': gap_ratio={gap_ratio:.1%} → {fill_policy}", flush=True)

    return aligned_metrics, max_gap_ratio, start_time, end_time


def get_static_threshold_fallback(tenant_id, service_name):
    """
    Lấy static threshold từ DynamoDB policy table để fallback
    """
    try:
        response = policy_table.get_item(Key={"tenant_id": tenant_id, "service_name": service_name})
        if "Item" in response:
            return float(response["Item"].get("static_threshold", 85.0))  # Default 85%
    except Exception as e:
        print(f"Lỗi đọc DynamoDB policy table: {str(e)}", flush=True)
    return 85.0


def as_dynamodb_number(value):
    """Convert Python numeric values to DynamoDB-safe Decimal values."""
    return Decimal(str(value))


def save_audit_log(
    prediction_id, tenant_id, service_name, decision, prediction_source, score,
    evidence_status="complete_window", anomaly=False, severity=0.0, reasoning="",
    recommendation=None, audit_id=None, ai_status_code=0, ai_latency_ms=0,
    deployment_version="v1.0.0", baseline_version="v1.0.0", prediction_status="complete",
    fallback_reason=None
):
    """
    TASK: CPOA-103 | CDO-W12-058 - Retention policies
    TASK: CPOA-63  | CDO-W12-022 - Bucket alignment + imputation (evidence_status)
    TASK: CPOA-68  | CDO-W12-027 - DynamoDB audit write (rich fields & idempotency check)
    OWNER: Tạ Hoàng Huy

    Lưu quyết định dự báo vào DynamoDB Audit Logs Table kèm TTL 90 ngày.
    Dùng ConditionExpression để đảm bảo tính Idempotency (CPOA-70).
    Lưu score và các trường dạng số đúng kiểu dữ liệu Number.
    """
    now = datetime.now(timezone.utc)
    now_epoch = int(now.timestamp())
    retention_seconds = 90 * 24 * 60 * 60
    expires_at_epoch = now_epoch + retention_seconds

    # Định nghĩa bản ghi với tất cả các design fields theo feedback
    item = {
        "tenant_id": tenant_id,
        "service_time": now.isoformat(),
        "prediction_status": prediction_status,
        "prediction_timestamp": now.isoformat(),
        "prediction_id": prediction_id,
        "service_name": service_name,
        "service_id": service_name,
        "timestamp": now_epoch,
        "decision": decision,
        "prediction_source": prediction_source,
        "score": as_dynamodb_number(score),
        "evidence_status": evidence_status,
        "anomaly": anomaly,
        "severity": as_dynamodb_number(severity),
        "reasoning": reasoning,
        "ai_status_code": as_dynamodb_number(ai_status_code),
        "ai_latency_ms": as_dynamodb_number(ai_latency_ms),
        "deployment_version": deployment_version,
        "baseline_version": baseline_version,
        "expires_at_epoch": expires_at_epoch
    }

    if fallback_reason:
        item["fallback_reason"] = fallback_reason

    # Bổ sung các thông tin recommendation nếu có
    if recommendation:
        item["recommendation_action"] = recommendation.get("action_verb", "INVESTIGATE")
        item["recommendation_target"] = recommendation.get("target", "")
        item["recommendation_from_to"] = recommendation.get("from_to", "")
        item["recommendation_confidence"] = as_dynamodb_number(recommendation.get("confidence", 0.0))
        item["recommendation_evidence"] = recommendation.get("evidence_link", "")

    if audit_id:
        item["audit_id"] = str(audit_id)

    try:
        # Idempotency Check: Chỉ ghi nếu cặp (tenant_id, service_time) chưa tồn tại
        audit_table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(tenant_id) AND attribute_not_exists(service_time)"
        )
        print(f"Successfully saved audit log for prediction: {prediction_id}", flush=True)
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            print(f"Idempotency warning: Audit log already exists for tenant {tenant_id} at this time. Skipping.", flush=True)
        else:
            print(f"Lỗi ghi DynamoDB audit log: {str(e)}", flush=True)
            raise e


def publish_sns_alert(prediction_id, tenant_id, service_name, decision, severity, reasoning):
    """
    TASK: CPOA-69 | CDO-W12-028 - SNS high-risk alert
    Gửi thông báo khẩn cấp tới SNS topic khi phát hiện anomaly hoặc hành động SCALE_UP/RETIRE nguy cơ cao.
    """
    if not ALERT_TOPIC_ARN or ALERT_TOPIC_ARN == "*":
        print("SNS Alert topic ARN is not configured or empty. Skipping alert.", flush=True)
        return

    subject = f"🔴 CDO High-Risk Alert: Anomaly detected on {service_name}"
    message = {
        "prediction_id": prediction_id,
        "tenant_id": tenant_id,
        "service_name": service_name,
        "decision": decision,
        "severity": severity,
        "reasoning": reasoning,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "alert_type": "HIGH_RISK_PREDICTION"
    }

    try:
        sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps(message, indent=2)
        )
        print(f"Successfully published high-risk alert to SNS: {ALERT_TOPIC_ARN}", flush=True)
    except Exception as e:
        print(f"Lỗi gửi SNS alert: {str(e)}", flush=True)


def process_job(job_data):
    """
    Xử lý một bản tin dự báo từ SQS
    """
    # 1. Parse các trường dữ liệu bắt buộc từ SQS Body
    prediction_id = job_data.get("correlation_id") or job_data.get("prediction_id") or str(uuid.uuid4())
    tenant_id = job_data.get("tenant_id")
    service_name = job_data.get("service_id") or job_data.get("service_name")
    lookback_window_minutes = job_data.get("lookback_window_minutes")
    
    if not tenant_id or not service_name:
        raise ValueError("Thiếu trường thông tin bắt buộc: tenant_id, service_id/service_name")

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
    
    # 3. Query metrics từ AMP với bucket alignment (CPOA-63)
    aligned_metrics, max_gap_ratio, start_time, end_time = query_amp_metrics(tenant_id, service_name, duration_minutes=lookback_val)

    # Xác định evidence_status: partial nếu có bất kỳ bucket bị thiếu
    evidence_status = "partial_window" if max_gap_ratio > 0.0 else "complete_window"
    print(f"Signal window: gap_ratio={max_gap_ratio:.1%} → evidence_status='{evidence_status}'", flush=True)

    # 4. Tạo signal_window và context payload theo đúng contract (CPOA-64)
    signal_window = []
    for metric_type, ts_val_map in aligned_metrics.items():
        for ts_int, val in ts_val_map.items():
            ts_iso = datetime.fromtimestamp(ts_int, tz=timezone.utc).isoformat().replace("+00:00", "Z")
            signal_window.append({
                "ts": ts_iso,
                "tenant_id": tenant_id,
                "service_id": service_name,
                "metric_type": metric_type,
                "value": float(val),
                "labels": {}
            })

    start_iso = datetime.fromtimestamp(start_time, tz=timezone.utc).isoformat().replace("+00:00", "Z")
    end_iso = datetime.fromtimestamp(end_time, tz=timezone.utc).isoformat().replace("+00:00", "Z")
    deployment_version = os.getenv("DEPLOYMENT_VERSION", "v1.0.0")

    payload = {
        "signal_window": signal_window,
        "context": {
            "deployment_version": deployment_version,
            "time_range": {
                "start_ts": start_iso,
                "end_ts": end_iso
            }
        }
    }

    # 5. Kiểm tra: nếu data gap quá lớn → không gọi AI, chuyển fallback ngay
    decision = "UNKNOWN"
    score = 0.0
    prediction_source = "AI_ENGINE"
    anomaly = False
    severity = 0.0
    reasoning = ""
    recommendation = None
    audit_id = None
    ai_status_code = 0
    ai_latency_ms = 0
    prediction_status = "complete"

    if max_gap_ratio >= MAX_GAP_THRESHOLD:
        print(f"Data gap {max_gap_ratio:.1%} vượt ngưỡng {MAX_GAP_THRESHOLD:.0%}. Không gọi AI, kích hoạt fallback.", flush=True)
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        reasoning = f"Data gap {max_gap_ratio:.1%} too large. Triggered static fallback."
    elif aligned_metrics:
        # 6. Gọi AI Engine bằng IAM SigV4 và validate response schema (CPOA-65, CPOA-66, CPOA-67)
        headers = {
            "X-Tenant-Id": tenant_id,
            "X-Correlation-Id": prediction_id,
            "Content-Type": "application/json"
        }
        
        # Tạo auth client động cho AI Engine
        ai_auth = get_aws_auth("execute-api")
        
        t0 = time.time()
        try:
            response = requests.post(
                AI_ENGINE_ENDPOINT,
                json=payload,
                headers=headers,
                auth=ai_auth,
                timeout=AI_TIMEOUT_SECONDS
            )
            ai_status_code = response.status_code
            ai_latency_ms = int((time.time() - t0) * 1000)

            if response.status_code == 200:
                result = response.json()
                
                # Validation schema (CPOA-67)
                if not isinstance(result, dict):
                    raise ValueError("AI response is not a JSON object")
                if "anomaly" not in result or not isinstance(result["anomaly"], bool):
                    raise ValueError("Missing or invalid 'anomaly' field")
                if "severity" not in result or not isinstance(result["severity"], (int, float)):
                    raise ValueError("Missing or invalid 'severity' field")
                if "reasoning" not in result or not isinstance(result["reasoning"], str):
                    raise ValueError("Missing or invalid 'reasoning' field")
                
                rec = result.get("recommendation")
                if rec is not None:
                    if not isinstance(rec, dict):
                        raise ValueError("Invalid 'recommendation' object")
                    for field in ["action_verb", "target", "from_to", "confidence", "evidence_link"]:
                        if field not in rec:
                            raise ValueError(f"Missing field '{field}' in recommendation")
                    if rec["action_verb"] not in ["SCALE_UP", "SCALE_DOWN", "RETIRE", "ROLLBACK", "INVESTIGATE"]:
                        raise ValueError(f"Invalid action_verb: {rec['action_verb']}")
                    if not isinstance(rec["confidence"], (int, float)):
                        raise ValueError("Invalid recommendation confidence score")

                # Parse kết quả sau khi pass validation
                anomaly = result["anomaly"]
                severity = float(result["severity"])
                reasoning = result["reasoning"]
                recommendation = rec
                audit_id = result.get("audit_id")
                
                if recommendation:
                    decision = recommendation["action_verb"]
                    score = float(recommendation.get("confidence", 0.0))
                else:
                    decision = "KEEP_ALIVE"
                    score = severity
                
            else:
                print(f"AI Engine trả về lỗi {response.status_code}. Kích hoạt Fallback.", flush=True)
                prediction_source = "STATIC_THRESHOLD_FALLBACK"
                prediction_status = "fallback"
                reasoning = f"AI Engine returned error HTTP {response.status_code}. Triggered fallback."
        except Exception as e:
            ai_latency_ms = int((time.time() - t0) * 1000)
            print(f"AI Engine không phản hồi: {str(e)}. Kích hoạt Fallback.", flush=True)
            prediction_source = "STATIC_THRESHOLD_FALLBACK"
            prediction_status = "fallback"
            reasoning = f"AI Engine call exception: {str(e)}. Triggered fallback."
    else:
        print("Địa chỉ AMP không trả về dữ liệu. Kích hoạt Fallback.", flush=True)
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        prediction_status = "fallback"
        reasoning = "No AMP metrics data available. Triggered fallback."

    # 7. Thực hiện tính toán fallback nếu cần
    if prediction_source == "STATIC_THRESHOLD_FALLBACK":
        threshold = get_static_threshold_fallback(tenant_id, service_name)
        score = threshold
        decision = "SCALE_UP" if score > 80.0 else "KEEP_ALIVE"
        anomaly = score > 80.0
        severity = score / 100.0
    
    # CPOA-72: đọc service policy trước khi quyết định gọi AI hay fallback
    policy = get_service_policy(tenant_id, service_name)
    fallback_reason = None  # THÊM — ghi vào audit khi prediction_source là fallback

    # CPOA-76: check signal window bằng policy (thay MAX_GAP_THRESHOLD cứng)
    window_ok, window_reason = check_signal_window(aligned_metrics, max_gap_ratio, policy)

    if not window_ok:
        print(f"{window_reason}. Không gọi AI, kích hoạt fallback.", flush=True)
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        prediction_status = "fallback"
        fallback_reason = "insufficient_signal_window"
        reasoning = window_reason
    elif aligned_metrics:
        # 6. Gọi AI Engine bằng IAM SigV4 và validate response schema (CPOA-65, CPOA-66, CPOA-67)
        headers = {
            "X-Tenant-Id": tenant_id,
            "X-Correlation-Id": prediction_id,
            "Content-Type": "application/json"
        }

        # Tạo auth client động cho AI Engine
        ai_auth = get_aws_auth("execute-api")

        # CPOA-73/74/75: gọi AI với retry 429/5xx + validate schema, trả fallback_reason nếu fail
        response, fallback_reason, ai_status_code, ai_latency_ms = call_ai_with_retry(
            payload, headers, ai_auth
        )

        if response is not None:
            result = response.json()

            anomaly = result["anomaly"]
            severity = float(result["severity"])
            reasoning = result["reasoning"]
            recommendation = result.get("recommendation")
            audit_id = result.get("audit_id")

            if recommendation:
                decision = recommendation["action_verb"]
                score = float(recommendation.get("confidence", 0.0))
            else:
                decision = "KEEP_ALIVE"
                score = severity
        else:
            print(f"AI Engine fail: {fallback_reason}. Kích hoạt Fallback.", flush=True)
            prediction_source = "STATIC_THRESHOLD_FALLBACK"
            prediction_status = "fallback"
            reasoning = f"AI Engine fallback_reason={fallback_reason}"
    else:
        print("Địa chỉ AMP không trả về dữ liệu. Kích hoạt Fallback.", flush=True)
        prediction_source = "STATIC_THRESHOLD_FALLBACK"
        prediction_status = "fallback"
        fallback_reason = "ai_timeout"  # không có data để gọi AI → coi như unavailable
        reasoning = "No AMP metrics data available. Triggered fallback."

    # 7. Thực hiện tính toán fallback nếu cần (CPOA-73/74/75: dùng policy.fallback_rules
    #    thay vì 1 threshold số duy nhất)
    if prediction_source == "STATIC_THRESHOLD_FALLBACK":
        fb = run_static_fallback(tenant_id, service_name, aligned_metrics, policy, fallback_reason)
        decision = fb["decision"]
        score = fb["score"]
        anomaly = fb["anomaly"]
        severity = fb["severity"]
        reasoning = fb["reasoning"]
        recommendation = fb["recommendation"]

    # 8. Lưu Audit Log kèm đầy đủ thông tin (CPOA-68)
    save_audit_log(
        prediction_id=prediction_id,
        tenant_id=tenant_id,
        service_name=service_name,
        decision=decision,
        prediction_source=prediction_source,
        score=score,
        evidence_status=evidence_status,
        anomaly=anomaly,
        severity=severity,
        reasoning=reasoning,
        recommendation=recommendation,
        audit_id=audit_id,
        ai_status_code=ai_status_code,
        ai_latency_ms=ai_latency_ms,
        deployment_version=deployment_version,
        prediction_status=prediction_status,
        fallback_reason=fallback_reason   # THÊM — CDO-W12-031/032/033/034
    )

    # 9. Gửi cảnh báo SNS nếu phát hiện anomaly nguy cơ cao (CPOA-69)
    if anomaly and (severity >= 0.8 or decision in ["SCALE_UP", "RETIRE"]):
        publish_sns_alert(prediction_id, tenant_id, service_name, decision, severity, reasoning)


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
                
                # Bọc try-catch riêng cho từng message để xử lý retry/DLQ (CPOA-61)
                try:
                    process_job(body)
                    # Xóa tin nhắn khỏi hàng đợi sau khi xử lý thành công
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=message["ReceiptHandle"]
                    )
                except Exception as inner_e:
                    print(f"Lỗi xử lý tin nhắn {message.get('MessageId')}: {str(inner_e)}", flush=True)
                    # Không xóa tin nhắn để SQS tự động retry dựa trên visibility timeout / maxReceiveCount
                    # Sau giới hạn retry limit, SQS sẽ tự động đưa vào DLQ
        except ClientError as e:
            print(f"Lỗi SQS Client: {str(e)}", flush=True)
            time.sleep(5)
        except Exception as e:
            print(f"Lỗi không xác định: {str(e)}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
