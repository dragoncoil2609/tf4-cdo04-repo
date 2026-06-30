"""
conftest.py — Integration test cho app.py (process_job end-to-end)
Mock TOÀN BỘ boundary bên ngoài: DynamoDB (audit_table, policy_table),
SNS, requests (AMP query + AI Engine call). Không gọi AWS/network thật.

Khác với tests/test_fallback/ (chỉ test fallback_engine.py đứng riêng),
bộ test này test app.process_job() — tức là kiểm tra TÍCH HỢP, không phải
từng hàm riêng lẻ.
"""
from unittest.mock import MagicMock
import pytest


@pytest.fixture(autouse=True)
def mock_all_aws_clients(monkeypatch):
    """
    Tự động mock mọi client AWS trong cả app.py và fallback_engine.py
    trước MỌI test trong folder này.
    """
    import app
    import fallback_engine as fe

    mock_audit_table = MagicMock()
    mock_policy_table = MagicMock()
    mock_sns = MagicMock()
    mock_sqs = MagicMock()

    monkeypatch.setattr(app, "audit_table", mock_audit_table)
    monkeypatch.setattr(app, "policy_table", mock_policy_table)
    monkeypatch.setattr(app, "sns", mock_sns)
    monkeypatch.setattr(app, "sqs", mock_sqs)

    # fallback_engine.py có policy_table riêng (đứng độc lập) — mock luôn
    monkeypatch.setattr(fe, "policy_table", mock_policy_table)

    # get_aws_auth gọi boto3.Session().get_credentials() — mock để không cần AWS creds thật
    monkeypatch.setattr(app, "get_aws_auth", lambda service: None)

    return {
        "audit_table": mock_audit_table,
        "policy_table": mock_policy_table,
        "sns": mock_sns,
        "sqs": mock_sqs,
    }


@pytest.fixture
def sample_policy():
    return {
        "tenant_id": "demo-tenant-001",
        "service_name": "payment-gateway",
        "enabled_metrics": ["api_latency_ms", "cpu_usage_percent"],
        "max_missing_buckets": 12,
        "fallback_rules": [
            {
                "metric_type": "api_latency_ms",
                "operator": ">",
                "threshold": 200,
                "duration_minutes": 10,
                "risk_level": "high",
                "recommendation": "Scale payment-gateway from 2 to 4 tasks",
            },
        ],
    }


@pytest.fixture
def valid_ai_response():
    return {
        "anomaly": True,
        "severity": 0.8,
        "reasoning": "api_latency_ms spike detected",
        "audit_id": "ai-audit-001",
        "recommendation": {
            "action_verb": "SCALE_UP",
            "target": "payment-gateway",
            "from_to": "2 -> 4",
            "confidence": 0.87,
            "evidence_link": "https://cloudwatch.example.com/x",
        },
    }


def mock_amp_response(value=45.0, num_points=120, step_seconds=60):
    """
    Giả lập response JSON từ AMP query_range — đủ 120 điểm liên tục,
    không có gap, để query_amp_metrics + align_and_impute build ra
    đúng 120 bucket khi test happy path.
    """
    import time
    end_time = int(time.time())
    start_time = end_time - (num_points * step_seconds)
    values = [[start_time + i * step_seconds, str(value)] for i in range(num_points + 1)]

    return MagicMock(
        status_code=200,
        json=lambda: {
            "data": {
                "result": [
                    {"metric": {}, "values": values}
                ]
            }
        }
    )


def mock_amp_empty_response():
    """AMP không trả data — dùng để test nhánh window thiếu"""
    return MagicMock(
        status_code=200,
        json=lambda: {"data": {"result": []}}
    )