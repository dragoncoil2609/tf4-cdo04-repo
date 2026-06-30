"""
conftest.py — pytest fixtures dùng chung
Mock boto3 trước khi import fallback_engine để không cần AWS credential thật.
"""
import sys
from unittest.mock import MagicMock
import pytest


@pytest.fixture(autouse=True)
def mock_boto3_before_import(monkeypatch):
    """
    Tự động chạy trước MỌI test — đảm bảo fallback_engine.policy_table
    luôn là MagicMock, không gọi AWS thật dù vô tình thiếu mock ở test riêng.
    """
    import fallback_engine as fe
    mock_table = MagicMock()
    monkeypatch.setattr(fe, "policy_table", mock_table)
    yield mock_table


@pytest.fixture
def sample_policy():
    """Policy mẫu cho payment-gateway theo seed_local.py đã dùng trước đó"""
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
            {
                "metric_type": "cpu_usage_percent",
                "operator": ">",
                "threshold": 85,
                "duration_minutes": 5,
                "risk_level": "medium",
                "recommendation": "Review cpu usage from 2 to 3 tasks",
            },
        ],
    }


@pytest.fixture
def full_window_metrics():
    """120 bucket đầy đủ, không gap — dùng cho happy path"""
    return {
        "api_latency_ms": {1_700_000_000 + i * 60: 45.0 for i in range(120)},
        "cpu_usage_percent": {1_700_000_000 + i * 60: 30.0 for i in range(120)},
    }


@pytest.fixture
def breach_window_metrics():
    """120 bucket đầy đủ nhưng giá trị vượt threshold — dùng để test anomaly detection"""
    return {
        "api_latency_ms": {1_700_000_000 + i * 60: 350.0 for i in range(120)},
        "cpu_usage_percent": {1_700_000_000 + i * 60: 30.0 for i in range(120)},
    }