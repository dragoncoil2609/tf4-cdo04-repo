"""Tests for Prometheus exporter and /metrics endpoint."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from telemetry_api.core.config import Settings
from telemetry_api.main import create_app


@pytest.fixture()
def client(tmp_path) -> TestClient:
    """Tạo TestClient dùng registry độc lập và file JSONL tạm thời."""

    settings = Settings(local_telemetry_file=str(tmp_path / "telemetry.jsonl"))
    return TestClient(create_app(settings))


def tenant_headers(correlation_id: str = "test-prometheus-001") -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "X-Tenant-Id": "demo-tenant-001",
        "X-Correlation-Id": correlation_id,
    }


def test_metrics_endpoint_status_and_format(client: TestClient) -> None:
    """GET /metrics returns 200 and Prometheus text format."""

    response = client.get("/metrics")
    assert response.status_code == 200

    assert "text/plain" in response.headers["content-type"]
    assert "charset=utf-8" in response.headers["content-type"]
    assert "# HELP cpu_usage_percent" in response.text


def test_valid_api_latency_ms_payload_updates_metrics(client: TestClient) -> None:
    """Valid api_latency_ms payload updates /metrics with proper format."""

    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "api_latency_ms",
        "value": 450.5,
        "labels": {"region": "us-east-1", "env": "production"}
    }

    res = client.post("/v1/ingest", json=payload, headers=tenant_headers())
    assert res.status_code == 201

    metrics_res = client.get("/metrics")
    assert metrics_res.status_code == 200
    assert 'api_latency_ms{env="production",region="us-east-1",service_id="payment-gateway",service_tier="",tenant_id="demo-tenant-001"} 450.5' in metrics_res.text


def test_valid_cpu_usage_percent_payload_updates_metrics(client: TestClient) -> None:
    """Valid cpu_usage_percent payload updates /metrics."""

    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "cpu_usage_percent",
        "value": 85.2,
        "labels": {"region": "us-east-1"}
    }

    res = client.post("/v1/ingest", json=payload, headers=tenant_headers())
    assert res.status_code == 201

    metrics_res = client.get("/metrics")
    assert 'cpu_usage_percent{env="",region="us-east-1",service_id="payment-gateway",service_tier="",tenant_id="demo-tenant-001"} 85.2' in metrics_res.text


def test_all_seven_allowlisted_metrics(client: TestClient) -> None:
    """All 7 allowlisted metrics can be emitted."""

    metrics_payloads = [
        ("cpu_usage_percent", {"region": "us-east-1"}),
        ("memory_usage_percent", {"region": "us-east-1"}),
        ("active_connections", {"region": "us-east-1"}),
        ("db_connection_pool_pct", {"region": "us-east-1", "db_type": "postgres"}),
        ("queue_depth", {"region": "us-east-1", "queue_name": "kyc"}),
        ("cache_hit_rate_pct", {"region": "us-east-1", "cache_type": "redis"}),
        ("api_latency_ms", {"region": "us-east-1"}),
    ]

    for metric, labels in metrics_payloads:
        payload = {
            "ts": "2026-06-25T10:30:00Z",
            "tenant_id": "demo-tenant-001",
            "service_id": "payment-gateway",
            "metric_type": metric,
            "value": 50.0,
            "labels": labels
        }
        res = client.post("/v1/ingest", json=payload, headers=tenant_headers(f"corr-{metric}"))
        assert res.status_code == 201

    metrics_res = client.get("/metrics")
    for metric, _ in metrics_payloads:
        assert f"{metric}{{" in metrics_res.text


def test_unsupported_and_internal_metrics_not_emitted(client: TestClient) -> None:
    """Unsupported metric and error_rate are rejected and not emitted."""

    # Unsupported metric
    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "random_metric",
        "value": 100,
        "labels": {"region": "us-east-1"}
    }
    res = client.post("/v1/ingest", json=payload, headers=tenant_headers())
    assert res.status_code == 400

    # Internal-only error_rate
    payload_err = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "error_rate",
        "value": 5,
        "labels": {"region": "us-east-1"}
    }
    res_err = client.post("/v1/ingest", json=payload_err, headers=tenant_headers())
    assert res_err.status_code == 400

    metrics_res = client.get("/metrics")
    assert "random_metric" not in metrics_res.text
    assert "error_rate" not in metrics_res.text


def test_pii_and_high_cardinality_rejected_and_not_emitted(client: TestClient) -> None:
    """PII and high-cardinality payloads are rejected and not emitted."""

    # PII payload
    payload_pii = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "cpu_usage_percent",
        "value": 50,
        "labels": {"region": "us-east-1", "email": "admin@cdo.com"}
    }
    res_pii = client.post("/v1/ingest", json=payload_pii, headers=tenant_headers())
    assert res_pii.status_code == 400

    # high-cardinality label payload
    payload_hc = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "cpu_usage_percent",
        "value": 50,
        "labels": {"region": "us-east-1", "session_id": "session-12345"}
    }
    res_hc = client.post("/v1/ingest", json=payload_hc, headers=tenant_headers())
    assert res_hc.status_code == 400

    metrics_res = client.get("/metrics")
    assert "admin@cdo.com" not in metrics_res.text
    assert "session-12345" not in metrics_res.text

    assert 'email=' not in metrics_res.text
    assert 'session_id=' not in metrics_res.text


def test_missing_required_label_rejected_and_not_emitted(client: TestClient) -> None:
    """Payload with missing required label is rejected and not emitted."""

    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "db_connection_pool_pct",
        "value": 45,
        "labels": {"region": "us-east-1"}  # thiếu db_type
    }
    res = client.post("/v1/ingest", json=payload, headers=tenant_headers())
    assert res.status_code == 400

    metrics_res = client.get("/metrics")
    assert "db_connection_pool_pct{" not in metrics_res.text


def test_metrics_no_sensitive_data_and_only_safe_labels(client: TestClient) -> None:
    """Metrics output does not include unsafe labels and includes only safe labels."""

    payload = {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "cpu_usage_percent",
        "value": 45,
        "labels": {
            "region": "us-east-1",
            "env": "production",
            "service_tier": "gold",
            "unsafe_label_ignored": "should-not-exist-in-metrics"
        }
    }

    res = client.post("/v1/ingest", json=payload, headers=tenant_headers())
    assert res.status_code == 201

    metrics_res = client.get("/metrics")
    assert "cpu_usage_percent" in metrics_res.text
    assert "unsafe_label_ignored" not in metrics_res.text
    assert "should-not-exist-in-metrics" not in metrics_res.text

    # Verify only safe labels are present
    assert 'cpu_usage_percent{env="production",region="us-east-1",service_id="payment-gateway",service_tier="gold",tenant_id="demo-tenant-001"}' in metrics_res.text
