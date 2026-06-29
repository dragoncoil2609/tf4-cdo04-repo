"""Unit tests for the telemetry payload idempotency key generator."""

from __future__ import annotations

from telemetry_api.core.idempotency import generate_idempotency_key
from telemetry_api.schemas.telemetry import TelemetryPayload


def test_same_payload_generates_same_key() -> None:
    """Hai payload giống hệt nhau phải tạo ra cùng một khóa idempotency."""

    p1 = TelemetryPayload(
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"region": "us-east-1", "env": "production"},
    )
    p2 = TelemetryPayload(
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"region": "us-east-1", "env": "production"},
    )

    k1 = generate_idempotency_key(p1)
    k2 = generate_idempotency_key(p2)

    assert k1 == k2
    assert len(k1) == 64  # SHA-256 length


def test_different_label_orders_generate_same_key() -> None:
    """Thứ tự khai báo nhãn khác nhau nhưng cùng nội dung phải tạo ra cùng khóa."""

    p1 = TelemetryPayload(
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"region": "us-east-1", "env": "production", "service_tier": "gold"},
    )
    # Khai báo labels với thứ tự chèn phần tử khác biệt
    p2 = TelemetryPayload(
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"service_tier": "gold", "env": "production", "region": "us-east-1"},
    )

    k1 = generate_idempotency_key(p1)
    k2 = generate_idempotency_key(p2)

    assert k1 == k2


def test_different_payloads_generate_different_keys() -> None:
    """Các payload khác nhau (về value, ts, tenant, vv) phải sinh ra khóa khác nhau."""

    base = TelemetryPayload(
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"region": "us-east-1"},
    )

    # 1. Khác value
    p1 = base.model_copy(update={"value": 450.6})
    # 2. Khác ts
    p2 = base.model_copy(update={"ts": "2026-06-25T10:30:01Z"})
    # 3. Khác tenant_id
    p3 = base.model_copy(update={"tenant_id": "demo-tenant-002"})

    k_base = generate_idempotency_key(base)
    k1 = generate_idempotency_key(p1)
    k2 = generate_idempotency_key(p2)
    k3 = generate_idempotency_key(p3)

    assert k_base != k1
    assert k_base != k2
    assert k_base != k3
