"""
test_ai_response_validation.py — CPOA-75 | CDO-W12-033
Kiểm chứng _validate_ai_response bắt đúng mọi trường hợp invalid.
Đây là phần quan trọng nhất để "biết AI Engine trả response đúng/sai".
"""
from unittest.mock import MagicMock
import fallback_engine as fe


def _mock_response(json_body, parse_error=False):
    resp = MagicMock()
    if parse_error:
        resp.json.side_effect = ValueError("invalid json")
    else:
        resp.json.return_value = json_body
    return resp


# ---------------------------------------------------------------------------
# Valid response — phải pass
# ---------------------------------------------------------------------------

def test_valid_full_response_passes():
    resp = _mock_response({
        "anomaly": True,
        "severity": 0.8,
        "reasoning": "Latency spike detected",
        "audit_id": "abc-123",
        "recommendation": {
            "action_verb": "SCALE_UP",
            "target": "payment-gateway",
            "from_to": "2 -> 4",
            "confidence": 0.87,
            "evidence_link": "https://cloudwatch.example.com/x",
        },
    })
    assert fe._validate_ai_response(resp) is True


def test_valid_response_without_recommendation_passes():
    """recommendation là optional — không có cũng phải pass"""
    resp = _mock_response({
        "anomaly": False,
        "severity": 0.1,
        "reasoning": "All normal",
        "audit_id": "abc-123",
    })
    assert fe._validate_ai_response(resp) is True


# ---------------------------------------------------------------------------
# Invalid — không parse được JSON
# ---------------------------------------------------------------------------

def test_unparseable_json_fails():
    resp = _mock_response(None, parse_error=True)
    assert fe._validate_ai_response(resp) is False


def test_response_not_dict_fails():
    resp = _mock_response(["not", "a", "dict"])
    assert fe._validate_ai_response(resp) is False


# ---------------------------------------------------------------------------
# Invalid — thiếu field bắt buộc
# ---------------------------------------------------------------------------

def test_missing_anomaly_fails():
    resp = _mock_response({"severity": 0.5, "reasoning": "x", "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


def test_missing_severity_fails():
    resp = _mock_response({"anomaly": True, "reasoning": "x", "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


def test_missing_reasoning_fails():
    resp = _mock_response({"anomaly": True, "severity": 0.5, "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


# ---------------------------------------------------------------------------
# Invalid — sai kiểu dữ liệu
# ---------------------------------------------------------------------------

def test_anomaly_as_string_fails():
    """anomaly phải là bool, không phải 'true' string"""
    resp = _mock_response({"anomaly": "true", "severity": 0.5, "reasoning": "x", "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


def test_severity_as_string_fails():
    """Điểm quan trọng nhất: severity PHẢI là number, không phải 'high'/'low'"""
    resp = _mock_response({"anomaly": True, "severity": "high", "reasoning": "x", "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


def test_reasoning_as_number_fails():
    resp = _mock_response({"anomaly": True, "severity": 0.5, "reasoning": 12345, "audit_id": "x"})
    assert fe._validate_ai_response(resp) is False


# ---------------------------------------------------------------------------
# Invalid — recommendation sai schema
# ---------------------------------------------------------------------------

def test_recommendation_not_dict_fails():
    resp = _mock_response({
        "anomaly": True, "severity": 0.5, "reasoning": "x", "audit_id": "x",
        "recommendation": "should be a dict not a string",
    })
    assert fe._validate_ai_response(resp) is False


def test_recommendation_missing_field_fails():
    resp = _mock_response({
        "anomaly": True, "severity": 0.5, "reasoning": "x", "audit_id": "x",
        "recommendation": {
            "action_verb": "SCALE_UP",
            "target": "x",
            # thiếu from_to, confidence, evidence_link
        },
    })
    assert fe._validate_ai_response(resp) is False


def test_recommendation_invalid_action_verb_fails():
    resp = _mock_response({
        "anomaly": True, "severity": 0.5, "reasoning": "x", "audit_id": "x",
        "recommendation": {
            "action_verb": "DESTROY_EVERYTHING",  # không thuộc enum hợp lệ
            "target": "x", "from_to": "x", "confidence": 0.5, "evidence_link": "x",
        },
    })
    assert fe._validate_ai_response(resp) is False


def test_recommendation_confidence_wrong_type_fails():
    resp = _mock_response({
        "anomaly": True, "severity": 0.5, "reasoning": "x", "audit_id": "x",
        "recommendation": {
            "action_verb": "SCALE_UP", "target": "x", "from_to": "x",
            "confidence": "very confident",  # phải là number
            "evidence_link": "x",
        },
    })
    assert fe._validate_ai_response(resp) is False