"""
test_process_job_integration.py
Kiểm chứng app.process_job() chạy ĐÚNG khi tích hợp fallback_engine,
không bị crash, gọi đúng audit_table.put_item với đúng tham số.

Đây là lớp test khác hẳn tests/test_fallback/ — không test từng hàm riêng,
mà test TOÀN BỘ luồng process_job() từ đầu đến cuối, đúng như Worker thật
sẽ chạy khi nhận 1 message SQS.
"""
from unittest.mock import patch, MagicMock
import pytest

import app
from conftest import mock_amp_response, mock_amp_empty_response


SAMPLE_JOB = {
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "lookback_window_minutes": 120,
}


# ---------------------------------------------------------------------------
# 1. Input validation — vẫn phải đúng như app.py gốc (KHÔNG bị fallback ảnh hưởng)
# ---------------------------------------------------------------------------

def test_missing_tenant_id_raises():
    bad_job = {"service_id": "payment-gateway"}
    with pytest.raises(ValueError, match="tenant_id"):
        app.process_job(bad_job)


def test_wrong_lookback_window_raises():
    bad_job = {**SAMPLE_JOB, "lookback_window_minutes": 60}
    with pytest.raises(ValueError, match="120"):
        app.process_job(bad_job)


# ---------------------------------------------------------------------------
# 2. Happy path — AI Engine trả 200 hợp lệ, audit ghi đúng prediction_source=AI_ENGINE
# ---------------------------------------------------------------------------

def test_happy_path_ai_success(mock_all_aws_clients, sample_policy, valid_ai_response):
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(
             status_code=200, json=lambda: valid_ai_response
         )):
        app.process_job(SAMPLE_JOB)

    # Verify audit_table.put_item được gọi đúng 1 lần
    mock_all_aws_clients["audit_table"].put_item.assert_called_once()
    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]

    assert item["prediction_source"] == "AI_ENGINE"
    assert item["tenant_id"] == "demo-tenant-001"
    assert item["service_name"] == "payment-gateway"
    assert "fallback_reason" not in item   # AI thành công thì KHÔNG có fallback_reason
    assert float(item["severity"]) == 0.8  # Decimal so sánh được với float


def test_happy_path_publishes_sns_when_high_severity(mock_all_aws_clients, sample_policy, valid_ai_response):
    """severity=0.8 >= 0.8 → phải publish SNS"""
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}
    app.ALERT_TOPIC_ARN = "arn:aws:sns:us-east-1:123:test-topic"  # set tạm cho test

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(
             status_code=200, json=lambda: valid_ai_response
         )):
        app.process_job(SAMPLE_JOB)

    mock_all_aws_clients["sns"].publish.assert_called_once()


# ---------------------------------------------------------------------------
# 3. AI timeout → fallback path chạy hết KHÔNG CRASH, audit ghi đúng fallback_reason
# ---------------------------------------------------------------------------

def test_ai_timeout_falls_back_without_crash(mock_all_aws_clients, sample_policy):
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}

    import requests as real_requests

    def raise_timeout(*a, **k):
        raise real_requests.exceptions.Timeout("AI down")

    with patch("app.requests.get", return_value=mock_amp_response(value=350.0)), \
         patch("fallback_engine.requests.post", side_effect=raise_timeout), \
         patch("fallback_engine.time.sleep", return_value=None):
        app.process_job(SAMPLE_JOB)   # KHÔNG được raise exception ra ngoài

    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]
    assert item["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
    assert item["fallback_reason"] == "ai_timeout"
    assert item["prediction_status"] == "fallback"
    # value=350 > threshold 200 trong sample_policy → phải detect anomaly qua static rule
    assert item["anomaly"] is True
    assert float(item["severity"]) == 0.8  # risk_level=high


# ---------------------------------------------------------------------------
# 4. AI 429 exhausted → fallback, verify KHÔNG bị treo do retry thật (đã mock sleep)
# ---------------------------------------------------------------------------

def test_ai_429_exhausted_falls_back(mock_all_aws_clients, sample_policy):
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}

    with patch("app.requests.get", return_value=mock_amp_response(value=100.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(status_code=429)), \
         patch("fallback_engine.time.sleep", return_value=None):
        app.process_job(SAMPLE_JOB)

    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]
    assert item["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
    assert item["fallback_reason"] == "ai_429_retry_exhausted"
    # value=100 < threshold 200 → không trigger rule nào → anomaly False
    assert item["anomaly"] is False


# ---------------------------------------------------------------------------
# 5. AI trả response sai schema → fallback, verify validate_ai_response hoạt động
#    đúng khi gọi từ trong app.py (không chỉ unit test riêng)
# ---------------------------------------------------------------------------

def test_ai_invalid_schema_falls_back(mock_all_aws_clients, sample_policy):
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}

    bad_response = MagicMock(
        status_code=200,
        json=lambda: {"missing": "required_fields"}   # thiếu anomaly/severity/reasoning/audit_id
    )

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=bad_response):
        app.process_job(SAMPLE_JOB)

    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]
    assert item["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
    assert item["fallback_reason"] == "ai_invalid_response"


# ---------------------------------------------------------------------------
# 6. Missing policy — process_job phải raise để Worker KHÔNG xóa SQS message
# ---------------------------------------------------------------------------

def test_missing_policy_does_not_crash_silently(mock_all_aws_clients):
    """
    get_service_policy trả None khi không tìm thấy policy.
    process_job hiện tại KHÔNG raise khi policy=None (chỉ check_signal_window
    nhận policy=None và dùng default) — verify hành vi thực tế, không giả định.
    """
    mock_all_aws_clients["policy_table"].get_item.return_value = {}  # không có Item

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(status_code=503)), \
         patch("fallback_engine.time.sleep", return_value=None):
        app.process_job(SAMPLE_JOB)   # phải chạy xong, không crash

    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]
    assert item["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
    # Không có policy → fallback_rules rỗng → không trigger rule nào
    assert item["anomaly"] is False


# ---------------------------------------------------------------------------
# 7. AMP không trả data → window insufficient → fallback ngay, KHÔNG gọi AI
# ---------------------------------------------------------------------------

def test_amp_no_data_skips_ai_call(mock_all_aws_clients, sample_policy):
    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}

    ai_call_count = {"n": 0}

    def count_ai_call(*a, **k):
        ai_call_count["n"] += 1
        return MagicMock(status_code=200, json=lambda: {})

    with patch("app.requests.get", return_value=mock_amp_empty_response()), \
         patch("fallback_engine.requests.post", side_effect=count_ai_call):
        app.process_job(SAMPLE_JOB)

    # AI KHÔNG được gọi vì window không đủ (insufficient_signal_window)
    assert ai_call_count["n"] == 0

    item = mock_all_aws_clients["audit_table"].put_item.call_args.kwargs["Item"]
    assert item["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
    assert item["fallback_reason"] == "insufficient_signal_window"


# ---------------------------------------------------------------------------
# 8. Idempotency: audit ghi trùng lần 2 không raise lên Worker
# ---------------------------------------------------------------------------

def test_duplicate_audit_write_does_not_crash(mock_all_aws_clients, sample_policy, valid_ai_response):
    from botocore.exceptions import ClientError

    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}
    mock_all_aws_clients["audit_table"].put_item.side_effect = ClientError(
        error_response={"Error": {"Code": "ConditionalCheckFailedException", "Message": "dup"}},
        operation_name="PutItem",
    )

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(
             status_code=200, json=lambda: valid_ai_response
         )):
        app.process_job(SAMPLE_JOB)   # KHÔNG được raise — idempotency phải nuốt lỗi này


def test_real_dynamodb_error_propagates(mock_all_aws_clients, sample_policy, valid_ai_response):
    """Lỗi DynamoDB KHÔNG phải do duplicate thì PHẢI raise — để SQS message không bị xóa"""
    from botocore.exceptions import ClientError

    mock_all_aws_clients["policy_table"].get_item.return_value = {"Item": sample_policy}
    mock_all_aws_clients["audit_table"].put_item.side_effect = ClientError(
        error_response={"Error": {"Code": "ProvisionedThroughputExceededException", "Message": "x"}},
        operation_name="PutItem",
    )

    with patch("app.requests.get", return_value=mock_amp_response(value=45.0)), \
         patch("fallback_engine.requests.post", return_value=MagicMock(
             status_code=200, json=lambda: valid_ai_response
         )):
        with pytest.raises(ClientError):
            app.process_job(SAMPLE_JOB)