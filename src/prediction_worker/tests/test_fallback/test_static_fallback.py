"""
test_static_fallback.py — CPOA-73/74/75 | CDO-W12-031/032/033
Kiểm chứng run_static_fallback evaluate đúng rule và severity number.
"""
import pytest
import fallback_engine as fe


# ---------------------------------------------------------------------------
# Happy path: không có anomaly
# ---------------------------------------------------------------------------

def test_no_breach_returns_normal(full_window_metrics, sample_policy):
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", full_window_metrics, sample_policy, "ai_timeout"
    )
    assert result["anomaly"] is False
    assert result["severity"] == 0.0
    assert result["decision"] == "KEEP_ALIVE"
    assert "ai_timeout" in result["reasoning"]


def test_missing_metric_in_data_skips_rule(sample_policy):
    """Rule cho api_latency_ms nhưng data không có metric đó → không trigger"""
    metrics = {"cpu_usage_percent": {1700000000: 30.0}}  # thiếu api_latency_ms
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", metrics, sample_policy, "ai_503"
    )
    assert result["anomaly"] is False


def test_no_policy_returns_normal(full_window_metrics):
    """Policy None → không có rule nào để evaluate"""
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", full_window_metrics, None, "ai_timeout"
    )
    assert result["anomaly"] is False


# ---------------------------------------------------------------------------
# Anomaly detected — severity number mapping
# ---------------------------------------------------------------------------

def test_high_risk_breach_severity_number(breach_window_metrics, sample_policy):
    """api_latency_ms=350 > threshold 200, risk=high → severity number 0.8"""
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", breach_window_metrics, sample_policy, "ai_timeout"
    )
    assert result["anomaly"] is True
    assert result["severity"] == 0.8           # high → 0.8 theo RISK_LEVEL_TO_SEVERITY
    assert isinstance(result["severity"], float)  # PHẢI là number, không phải string
    assert result["decision"] == "SCALE_UP"


def test_severity_is_never_string():
    """Regression test quan trọng: severity TUYỆT ĐỐI không được là string
    vì app.py mới dùng as_dynamodb_number(severity) — string sẽ crash DynamoDB write"""
    policy = {
        "enabled_metrics": ["queue_depth"],
        "fallback_rules": [{
            "metric_type": "queue_depth", "operator": ">", "threshold": 5000,
            "risk_level": "critical", "recommendation": "Scale from 20 to 40",
        }]
    }
    metrics = {"queue_depth": {1700000000: 6000.0}}
    result = fe.run_static_fallback("t1", "kyc-worker", metrics, policy, "ai_5xx")
    assert isinstance(result["severity"], (int, float))
    assert not isinstance(result["severity"], str)
    assert isinstance(result["score"], (int, float))
    assert isinstance(result["anomaly"], bool)


@pytest.mark.parametrize("risk_level,expected_severity", [
    ("low", 0.2),
    ("medium", 0.5),
    ("high", 0.8),
    ("critical", 0.95),
])
def test_risk_level_severity_mapping(risk_level, expected_severity):
    policy = {
        "enabled_metrics": ["api_latency_ms"],
        "fallback_rules": [{
            "metric_type": "api_latency_ms", "operator": ">", "threshold": 100,
            "risk_level": risk_level, "recommendation": "Scale from 2 to 4",
        }]
    }
    metrics = {"api_latency_ms": {1700000000: 200.0}}
    result = fe.run_static_fallback("t1", "svc", metrics, policy, "ai_timeout")
    assert result["severity"] == expected_severity


# ---------------------------------------------------------------------------
# Multiple rules — chọn rule nghiêm trọng nhất
# ---------------------------------------------------------------------------

def test_multiple_rules_pick_highest_severity():
    policy = {
        "enabled_metrics": ["api_latency_ms", "cpu_usage_percent"],
        "fallback_rules": [
            {"metric_type": "api_latency_ms", "operator": ">", "threshold": 200,
             "risk_level": "medium", "recommendation": "Review from 2 to 3"},
            {"metric_type": "cpu_usage_percent", "operator": ">", "threshold": 80,
             "risk_level": "critical", "recommendation": "Scale from 2 to 6"},
        ]
    }
    metrics = {
        "api_latency_ms": {1700000000: 250.0},
        "cpu_usage_percent": {1700000000: 95.0},
    }
    result = fe.run_static_fallback("t1", "svc", metrics, policy, "ai_invalid_response")
    assert result["severity"] == 0.95  # critical thắng medium
    assert result["decision"] == "SCALE_UP"


# ---------------------------------------------------------------------------
# Recommendation structure — phải match schema app.py mong đợi
# ---------------------------------------------------------------------------

def test_recommendation_has_required_fields(breach_window_metrics, sample_policy):
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", breach_window_metrics, sample_policy, "ai_timeout"
    )
    rec = result["recommendation"]
    assert rec is not None
    required = {"action_verb", "target", "from_to", "confidence", "evidence_link"}
    assert required.issubset(rec.keys())
    assert rec["action_verb"] in {"SCALE_UP", "SCALE_DOWN", "RETIRE", "ROLLBACK", "INVESTIGATE"}


def test_no_breach_recommendation_is_none(full_window_metrics, sample_policy):
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", full_window_metrics, sample_policy, "ai_timeout"
    )
    assert result["recommendation"] is None


# ---------------------------------------------------------------------------
# _extract_latest_values — đúng format dict {ts: value}
# ---------------------------------------------------------------------------

def test_extract_latest_picks_max_timestamp():
    metrics = {
        "api_latency_ms": {
            1000: 40.0,
            3000: 60.0,   # timestamp lớn nhất → phải lấy giá trị này
            2000: 50.0,
        }
    }
    latest = fe._extract_latest_values(metrics)
    assert latest["api_latency_ms"] == 60.0


def test_extract_latest_empty_metric_skipped():
    metrics = {"api_latency_ms": {}}
    latest = fe._extract_latest_values(metrics)
    assert "api_latency_ms" not in latest


# ---------------------------------------------------------------------------
# fallback_reason luôn được giữ trong reasoning để audit truy vết
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("reason", [
    "ai_timeout", "ai_429_retry_exhausted", "ai_503", "ai_5xx",
    "ai_invalid_response", "insufficient_signal_window", "ai_400",
])
def test_fallback_reason_appears_in_reasoning(full_window_metrics, sample_policy, reason):
    result = fe.run_static_fallback(
        "demo-tenant-001", "payment-gateway", full_window_metrics, sample_policy, reason
    )
    assert reason in result["reasoning"]