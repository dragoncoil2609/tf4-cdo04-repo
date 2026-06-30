# ===========================================================================
# FALLBACK ENGINE — Phan Minh Tuấn (CPOA-71..77)
# ===========================================================================
# Module này được import vào app.py. KHÔNG đổi style/comment của app.py gốc.
# Format dữ liệu input đã đổi theo app.py v2 của Hoàng:
#   aligned_metrics: {metric_type: {ts_int: float}}   (KHÔNG còn list of series)
#   severity:        number 0.0-1.0                    (KHÔNG còn string low/high)

import os
import time

import boto3
import requests

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
AI_ENGINE_ENDPOINT = os.getenv("AI_ENGINE_ENDPOINT", "http://ai-engine.cdo-services/v1/predict")
AI_TIMEOUT_SECONDS = float(os.getenv("AI_TIMEOUT_SECONDS", "2"))
DYNAMODB_POLICY_TABLE = os.getenv("DYNAMODB_POLICY_TABLE", "cdo04-service-policies")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
policy_table = dynamodb.Table(DYNAMODB_POLICY_TABLE)

REQUIRED_BUCKETS = 120          # 120 phút, step 60s
MAX_MISSING_BUCKETS_DEFAULT = 12  # 10% của 120
STATIC_FALLBACK_CONFIDENCE = 0.6

# Severity number mapping cho fallback rules (risk_level string → severity float)
# Dùng để tương thích với schema severity number của AI contract trong app.py
RISK_LEVEL_TO_SEVERITY = {
    "low": 0.2,
    "medium": 0.5,
    "high": 0.8,
    "critical": 0.95,
}


# ---------------------------------------------------------------------------
# CPOA-72: Đọc service policy (fallback_rules) từ DynamoDB
# ---------------------------------------------------------------------------
def get_service_policy(tenant_id, service_name):
    """
    TASK: CPOA-72 | CDO-W12-030 — DynamoDB service policy fallback rules
    OWNER: Phan Minh Tuấn

    Đọc policy theo tenant_id + service_name.
    Policy có enabled_metrics, threshold, duration_minutes,
    recommendation, baseline_version.

    Returns: dict policy hoặc None nếu không tìm thấy.
    Missing policy → caller xử lý safe fallback hoặc DLQ.
    """
    try:
        response = policy_table.get_item(
            Key={
                "tenant_id": tenant_id,
                "service_name": service_name,
            }
        )
        item = response.get("Item")
        if not item:
            print(
                f"[FALLBACK] Policy không tìm thấy: tenant={tenant_id} service={service_name}",
                flush=True,
            )
        return item
    except Exception as e:
        print(f"[FALLBACK] Lỗi đọc policy DynamoDB: {str(e)}", flush=True)
        return None


# ---------------------------------------------------------------------------
# CPOA-76: Check signal window đủ 120 bucket chưa
# ---------------------------------------------------------------------------
def check_signal_window(aligned_metrics, max_gap_ratio, policy=None):
    """
    TASK: CPOA-76 | CDO-W12-034 — Insufficient AMP window fallback
    OWNER: Phan Minh Tuấn

    Kiểm tra aligned_metrics (output của align_and_impute trong app.py)
    có đủ 120 bucket và gap_ratio nằm trong policy cho phép không.

    aligned_metrics format (đúng theo app.py v2):
        {metric_type: {ts_int: float}, ...}

    Returns: (ok: bool, reason: str | None)
    """
    if not aligned_metrics:
        return False, "insufficient_signal_window: no metrics returned from AMP"

    max_missing = MAX_MISSING_BUCKETS_DEFAULT
    if policy:
        max_missing = policy.get("max_missing_buckets", MAX_MISSING_BUCKETS_DEFAULT)
    max_gap_threshold = max_missing / REQUIRED_BUCKETS

    for metric_type, ts_val_map in aligned_metrics.items():
        actual_buckets = len(ts_val_map)
        if actual_buckets < REQUIRED_BUCKETS:
            reason = (
                f"insufficient_signal_window: {metric_type} only has "
                f"{actual_buckets}/{REQUIRED_BUCKETS} buckets"
            )
            print(f"[FALLBACK] {reason}", flush=True)
            return False, reason

    if max_gap_ratio > max_gap_threshold:
        reason = (
            f"insufficient_signal_window: gap_ratio={max_gap_ratio:.1%} "
            f"exceeds policy limit {max_gap_threshold:.1%}"
        )
        print(f"[FALLBACK] {reason}", flush=True)
        return False, reason

    return True, None


# ---------------------------------------------------------------------------
# CPOA-73/74/75: Static threshold fallback engine
# ---------------------------------------------------------------------------
def run_static_fallback(tenant_id, service_name, aligned_metrics, policy, fallback_reason):
    """
    TASK: CPOA-73/74/75 | CDO-W12-031/032/033
    OWNER: Phan Minh Tuấn

    Evaluate static threshold rules từ policy.fallback_rules.
    Dùng khi AI timeout, 429/5xx, response invalid, hoặc insufficient window.

    aligned_metrics format (đúng theo app.py v2):
        {metric_type: {ts_int: float}, ...}

    Returns: dict {decision, score, anomaly, severity, reasoning, recommendation}
        severity trả về number (0.0-1.0) để tương thích với save_audit_log của app.py
    """
    fallback_rules = policy.get("fallback_rules", []) if policy else []
    enabled_metrics = (
        policy.get("enabled_metrics", list(aligned_metrics.keys()))
        if policy
        else list(aligned_metrics.keys())
    )

    latest_values = _extract_latest_values(aligned_metrics)

    triggered_rules = []
    for rule in fallback_rules:
        metric_type = rule.get("metric_type")
        if metric_type not in enabled_metrics:
            continue
        current_value = latest_values.get(metric_type)
        if current_value is None:
            continue
        if _evaluate_rule(current_value, rule):
            triggered_rules.append(rule)
            print(
                f"[FALLBACK] Rule triggered: {metric_type}"
                f" {rule.get('operator')} {rule.get('threshold')}"
                f" (current={current_value:.2f}) risk={rule.get('risk_level')}",
                flush=True,
            )

    if not triggered_rules:
        return {
            "decision": "KEEP_ALIVE",
            "score": 0.0,
            "anomaly": False,
            "severity": 0.0,
            "reasoning": f"No static threshold breached. fallback_reason={fallback_reason}",
            "recommendation": None,
        }

    severity_order = {"low": 1, "medium": 2, "high": 3, "critical": 4}
    top_rule = max(
        triggered_rules,
        key=lambda r: severity_order.get(r.get("risk_level", "low"), 0)
    )
    risk_level = top_rule.get("risk_level", "medium")
    severity_number = RISK_LEVEL_TO_SEVERITY.get(risk_level, 0.5)

    return {
        "decision": "SCALE_UP" if risk_level in ("high", "critical") else "ALERT",
        "score": STATIC_FALLBACK_CONFIDENCE,
        "anomaly": True,
        "severity": severity_number,
        "reasoning": (
            f"Static threshold breach. fallback_reason={fallback_reason}. "
            f"Triggered: "
            + ", ".join(
                f"{r.get('metric_type')}{r.get('operator')}{r.get('threshold')}"
                f"(risk={r.get('risk_level')})"
                for r in triggered_rules
            )
        ),
        "recommendation": {
            "action_verb": "SCALE_UP" if risk_level in ("high", "critical") else "INVESTIGATE",
            "target": top_rule.get("metric_type", ""),
            "from_to": top_rule.get("recommendation", ""),
            "confidence": STATIC_FALLBACK_CONFIDENCE,
            "evidence_link": "",
        },
    }


def _extract_latest_values(aligned_metrics):
    """
    Lấy giá trị mới nhất (bucket có ts lớn nhất) của mỗi metric.
    aligned_metrics format: {metric_type: {ts_int: float}, ...}
    """
    latest = {}
    for metric_type, ts_val_map in aligned_metrics.items():
        if not ts_val_map:
            continue
        latest_ts = max(ts_val_map.keys())
        latest[metric_type] = ts_val_map[latest_ts]
    return latest


def _evaluate_rule(current_value, rule):
    """So sánh current_value với threshold theo operator của rule."""
    op = rule.get("operator", ">")
    threshold = float(rule.get("threshold", 0))
    if op == ">":  return current_value > threshold
    if op == ">=": return current_value >= threshold
    if op == "<":  return current_value < threshold
    if op == "<=": return current_value <= threshold
    if op == "==": return current_value == threshold
    return False


# ---------------------------------------------------------------------------
# CPOA-73/74: Retry logic cho 429 và 5xx (dùng auth + headers giống app.py)
# ---------------------------------------------------------------------------
def call_ai_with_retry(payload, headers, ai_auth):
    """
    TASK: CPOA-73/74 | CDO-W12-031/032
    OWNER: Phan Minh Tuấn

    Gọi AI Engine với retry/fallback theo từng loại lỗi:
    - Timeout > 2s          → ai_timeout (không retry)
    - 429                   → retry exponential backoff 1s→2s→4s
    - 503/5xx               → retry giới hạn 2 lần
    - 400                   → không retry
    - Response sai schema   → ai_invalid_response

    headers/ai_auth truyền vào từ app.py để giữ đúng IAM SigV4 + X-Tenant-Id
    đã build trong process_job.

    Returns: (response | None, fallback_reason | None, ai_status_code, ai_latency_ms)
        response = requests.Response object nếu 200 + schema hợp lệ
    """
    RETRY_DELAYS_429 = [1, 2, 4]
    MAX_5XX_RETRIES = 2

    t0 = time.time()
    try:
        response = requests.post(
            AI_ENGINE_ENDPOINT,
            json=payload,
            headers=headers,
            auth=ai_auth,
            timeout=AI_TIMEOUT_SECONDS,
        )
    except requests.exceptions.Timeout:
        latency = int((time.time() - t0) * 1000)
        print(
            f"[FALLBACK] AI Engine timeout sau {AI_TIMEOUT_SECONDS}s → ai_timeout",
            flush=True,
        )
        return None, "ai_timeout", 0, latency
    except Exception as e:
        latency = int((time.time() - t0) * 1000)
        print(f"[FALLBACK] AI Engine connection error: {str(e)}", flush=True)
        return None, "ai_timeout", 0, latency

    status = response.status_code
    latency = int((time.time() - t0) * 1000)

    if status == 400:
        print("[FALLBACK] AI Engine 400 Bad Request — không retry", flush=True)
        return None, "ai_400", status, latency

    if status == 429:
        for delay in RETRY_DELAYS_429:
            print(f"[FALLBACK] AI Engine 429 — retry sau {delay}s", flush=True)
            time.sleep(delay)
            try:
                resp = requests.post(
                    AI_ENGINE_ENDPOINT, json=payload, headers=headers,
                    auth=ai_auth, timeout=AI_TIMEOUT_SECONDS,
                )
                if resp.status_code == 200:
                    if _validate_ai_response(resp):
                        return resp, None, resp.status_code, latency
                    return None, "ai_invalid_response", resp.status_code, latency
                if resp.status_code != 429:
                    status = resp.status_code
                    break
            except Exception:
                break
        print("[FALLBACK] AI Engine 429 retry exhausted", flush=True)
        return None, "ai_429_retry_exhausted", status, latency

    if status in (500, 502, 503, 504):
        for attempt in range(1, MAX_5XX_RETRIES + 1):
            print(f"[FALLBACK] AI Engine {status} — retry attempt {attempt}", flush=True)
            time.sleep(attempt)
            try:
                resp = requests.post(
                    AI_ENGINE_ENDPOINT, json=payload, headers=headers,
                    auth=ai_auth, timeout=AI_TIMEOUT_SECONDS,
                )
                if resp.status_code == 200:
                    if _validate_ai_response(resp):
                        return resp, None, resp.status_code, latency
                    return None, "ai_invalid_response", resp.status_code, latency
            except Exception:
                continue
        reason = "ai_503" if status == 503 else "ai_5xx"
        print(f"[FALLBACK] AI Engine {status} retry exhausted → {reason}", flush=True)
        return None, reason, status, latency

    if status == 200:
        if _validate_ai_response(response):
            return response, None, status, latency
        return None, "ai_invalid_response", status, latency

    print(f"[FALLBACK] AI Engine unexpected status {status}", flush=True)
    return None, "ai_5xx", status, latency


# ---------------------------------------------------------------------------
# CPOA-75: Validate AI response schema
# ---------------------------------------------------------------------------
def _validate_ai_response(response):
    """
    TASK: CPOA-75 | CDO-W12-033 — Invalid AI response fallback
    OWNER: Phan Minh Tuấn

    Validate required fields và kiểu dữ liệu theo schema thật trong app.py:
    anomaly (bool), severity (number), reasoning (str), recommendation (optional dict).
    Không log full payload — chỉ log error summary.

    Returns: True nếu valid, False nếu invalid.
    """
    try:
        data = response.json()
    except Exception:
        print("[FALLBACK] AI response không parse được JSON", flush=True)
        return False

    if not isinstance(data, dict):
        print("[FALLBACK] AI response không phải JSON object", flush=True)
        return False

    if "anomaly" not in data or not isinstance(data["anomaly"], bool):
        print("[FALLBACK] AI response thiếu hoặc sai kiểu field 'anomaly'", flush=True)
        return False

    if "severity" not in data or not isinstance(data["severity"], (int, float)):
        print("[FALLBACK] AI response thiếu hoặc sai kiểu field 'severity'", flush=True)
        return False

    if "reasoning" not in data or not isinstance(data["reasoning"], str):
        print("[FALLBACK] AI response thiếu hoặc sai kiểu field 'reasoning'", flush=True)
        return False

    rec = data.get("recommendation")
    if rec is not None:
        if not isinstance(rec, dict):
            print("[FALLBACK] AI response 'recommendation' không phải object", flush=True)
            return False
        required_rec_fields = {"action_verb", "target", "from_to", "confidence", "evidence_link"}
        missing_rec = required_rec_fields - rec.keys()
        if missing_rec:
            print(f"[FALLBACK] AI response recommendation thiếu field: {missing_rec}", flush=True)
            return False
        valid_actions = {"SCALE_UP", "SCALE_DOWN", "RETIRE", "ROLLBACK", "INVESTIGATE"}
        if rec["action_verb"] not in valid_actions:
            print(f"[FALLBACK] AI response action_verb không hợp lệ: {rec['action_verb']!r}", flush=True)
            return False
        if not isinstance(rec["confidence"], (int, float)):
            print("[FALLBACK] AI response recommendation.confidence sai kiểu", flush=True)
            return False

    return True