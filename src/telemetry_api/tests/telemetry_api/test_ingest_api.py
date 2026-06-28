"""Kiểm thử endpoint POST /v1/ingest và các quy tắc Schema Validation."""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from telemetry_api.core.config import Settings
from telemetry_api.main import create_app
from telemetry_api.schemas.telemetry import TelemetryPayload


logger = logging.getLogger("telemetry_api.ingest")


def valid_payload() -> dict[str, object]:
    """Trả về body telemetry ingest hợp lệ theo giao ước."""

    return {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "api_latency_ms",
        "value": 450.5,
        "labels": {"region": "us-east-1"},
    }


@pytest.fixture()
def telemetry_file(tmp_path: Path) -> Path:
    """Trả về đường dẫn JSONL tách biệt cho từng API test."""

    return tmp_path / "local-store" / "telemetry.jsonl"


@pytest.fixture()
def client(telemetry_file: Path) -> TestClient:
    """Tạo TestClient dùng file JSONL local tạm thời."""

    settings = Settings(local_telemetry_file=str(telemetry_file), log_level="INFO")
    return TestClient(create_app(settings))


@pytest.fixture(autouse=True)
def reset_metrics():
    """Tự động đặt lại các bộ đếm đo lường trước và sau mỗi test case."""

    from telemetry_api.observability.metrics import reset_metrics_for_tests
    reset_metrics_for_tests()
    yield
    reset_metrics_for_tests()


def tenant_headers(correlation_id: str = "local-test-001") -> dict[str, str]:
    """Trả về header chuẩn cho request ingest có scope tenant hợp lệ."""

    return {
        "Content-Type": "application/json",
        "X-Tenant-Id": "demo-tenant-001",
        "X-Correlation-Id": correlation_id,
    }


def post_ingest(client: TestClient, payload: dict[str, object], headers: dict[str, str] | None = None):
    """Gửi request ingest với các giá trị mặc định dùng chung."""

    return client.post("/v1/ingest", json=payload, headers=headers or tenant_headers())


# --- 1. KIỂM THỬ PAYLOAD HỢP LỆ VÀ GHI FILE ---

def test_valid_payload_returns_201_and_writes_jsonl(client: TestClient, telemetry_file: Path) -> None:
    """Datapoint telemetry hợp lệ được chấp nhận và ghi nối tiếp vào JSONL local."""

    response = post_ingest(client, valid_payload())

    assert response.status_code == 201
    assert response.json() == {
        "status": "accepted",
        "correlation_id": "local-test-001",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "api_latency_ms",
    }

    lines = telemetry_file.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    stored = json.loads(lines[0])
    assert stored["correlation_id"] == "local-test-001"
    assert stored["tenant_id"] == "demo-tenant-001"
    assert stored["service_id"] == "payment-gateway"
    assert stored["metric_type"] == "api_latency_ms"
    assert stored["value"] == 450.5
    assert stored["labels"] == {"region": "us-east-1"}
    assert stored["ingest_source"] == "local_api"
    assert stored["received_at"].endswith("Z")


# --- 2. KIỂM THỬ PHÂN TÍCH METRICS & LỖI THIẾU TRƯỜNG ---

def test_metrics_endpoint_initial_state(client: TestClient) -> None:
    """Kiểm tra giá trị ban đầu của /metrics khi chưa có request."""

    response = client.get("/metrics")
    assert response.status_code == 200
    data = response.json()
    assert data["telemetry_ingest_accepted_total"] == 0
    assert data["telemetry_ingest_rejected_total"] == 0
    assert data["telemetry_ingest_rejected_by_reason"] == {}


def test_accepted_request_increments_metric(client: TestClient) -> None:
    """Request thành công sẽ tăng bộ đếm accepted lên 1."""

    response = post_ingest(client, valid_payload())
    assert response.status_code == 201

    metrics_resp = client.get("/metrics")
    data = metrics_resp.json()
    assert data["telemetry_ingest_accepted_total"] == 1
    assert data["telemetry_ingest_rejected_total"] == 0


@pytest.mark.parametrize("missing_field", ["tenant_id", "service_id", "metric_type", "ts", "value"])
def test_missing_required_fields_return_400(client: TestClient, missing_field: str) -> None:
    """Mỗi field body bắt buộc đều trả HTTP 400 và tăng rejection metrics khi bị thiếu."""

    payload = valid_payload()
    payload.pop(missing_field)

    response = post_ingest(client, payload)

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert response.json()["correlation_id"] == "local-test-001"

    # Kiểm tra metric ghi nhận lý do thiếu trường
    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_total"] == 1
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["missing_required_field"] == 1


# --- 3. KIỂM THỬ VALIDATE TIMESTAMP (ts) ---

@pytest.mark.parametrize("ts_val, expected_status, expected_reason", [
    ("2026-06-25T10:30:00Z", 201, None),
    ("2026-06-25T10:30:00+00:00", 201, None),
    ("2026-06-25T10:30:00+0000", 201, None),
    ("2026-06-25 10:30:00", 400, "invalid_timestamp"),
    ("2026-06-25T10:30:00", 400, "invalid_timestamp"),
    ("2026-06-25T10:30:00+07:00", 400, "invalid_timestamp"),
    ("not-a-date", 400, "invalid_timestamp"),
    (1719300000, 400, "invalid_timestamp"),
])
def test_timestamp_validation(client: TestClient, ts_val: Any, expected_status: int, expected_reason: str | None) -> None:
    """Kiểm tra tính nghiêm ngặt của timestamp định dạng RFC3339 UTC."""

    payload = valid_payload()
    payload["ts"] = ts_val

    response = post_ingest(client, payload)
    assert response.status_code == expected_status

    if expected_status == 400:
        assert response.json()["error"] == "bad_request"
        metrics_data = client.get("/metrics").json()
        assert metrics_data["telemetry_ingest_rejected_total"] == 1
        assert metrics_data["telemetry_ingest_rejected_by_reason"][expected_reason] == 1


# --- 4. KIỂM THỬ VALIDATE GIÁ TRỊ ĐO LƯỜNG (value) ---

@pytest.mark.parametrize("value_val, expected_status, expected_reason", [
    (450, 201, None),
    (450.5, 201, None),
    ("450.5", 400, "invalid_value"),
    (True, 400, "invalid_value"),
    (False, 400, "invalid_value"),
])
def test_value_validation(client: TestClient, value_val: Any, expected_status: int, expected_reason: str | None) -> None:
    """Giá trị metric bắt buộc phải là số thực hoặc số nguyên (không nhận chuỗi, boolean)."""

    payload = valid_payload()
    payload["value"] = value_val

    response = post_ingest(client, payload)
    assert response.status_code == expected_status

    if expected_status == 400:
        metrics_data = client.get("/metrics").json()
        assert metrics_data["telemetry_ingest_rejected_total"] == 1
        assert metrics_data["telemetry_ingest_rejected_by_reason"][expected_reason] == 1


def test_nan_infinity_value_validation() -> None:
    """Kiểm tra NaN và Infinity trực tiếp trên model validation của Pydantic."""

    for val in [float("nan"), float("inf"), float("-inf")]:
        payload = valid_payload()
        payload["value"] = val
        with pytest.raises(ValidationError) as exc_info:
            TelemetryPayload.model_validate(payload)
        assert "value must be a finite number" in str(exc_info.value)


# --- 5. KIỂM THỬ CHUỖI KHÔNG ĐƯỢC RỖNG & ALLOWLIST METRICS ---

@pytest.mark.parametrize("field, val, expected_reason", [
    ("tenant_id", "", "empty_tenant_id"),
    ("tenant_id", "   ", "empty_tenant_id"),
    ("tenant_id", 123, "empty_tenant_id"),
    ("service_id", "", "empty_service_id"),
    ("service_id", "   ", "empty_service_id"),
    ("metric_type", "", "empty_metric_type"),
    ("metric_type", "   ", "empty_metric_type"),
])
def test_non_empty_string_fields(client: TestClient, field: str, val: Any, expected_reason: str) -> None:
    """Các trường text định danh phải là kiểu chuỗi và không được để trống hoặc chỉ có khoảng trắng."""

    payload = valid_payload()
    payload[field] = val

    response = post_ingest(client, payload)
    assert response.status_code == 400

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_total"] == 1
    assert metrics_data["telemetry_ingest_rejected_by_reason"][expected_reason] == 1


def test_unsupported_metric_type_returns_400(client: TestClient) -> None:
    """Metric type phải nằm trong danh sách được phép."""

    payload = valid_payload()
    payload["metric_type"] = "unknown_metric"

    response = post_ingest(client, payload)

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["unsupported_metric_type"] == 1


# --- 6. KIỂM THỬ VALIDATE LABELS ĐƠN GIẢN & AN TOÀN ---

@pytest.mark.parametrize("labels_val, expected_status, expected_reason", [
    (None, 201, None),
    ({}, 201, None),
    ({"region": "us-east-1", "env": "local", "status": True, "code": 200, "empty": None}, 201, None),
    ("region=us-east-1", 400, "invalid_labels_type"),
    (["region", "us-east-1"], 400, "invalid_labels_type"),
    ({"region": {"name": "us-east-1"}}, 400, "nested_label_object"),
    ({"regions": ["us-east-1"]}, 400, "nested_label_object"),
    ({"request_id": "req-123"}, 400, "high_cardinality_label"),
    ({"token": "abc"}, 400, "sensitive_label"),
    ({"my_label": "my-secret-password"}, 400, "sensitive_label"),
])
def test_labels_validation(client: TestClient, labels_val: Any, expected_status: int, expected_reason: str | None) -> None:
    """Kiểm tra các ràng buộc kiểu nhãn labels phẳng, PII và High-cardinality."""

    payload = valid_payload()
    if labels_val is None:
        payload.pop("labels", None)
    else:
        payload["labels"] = labels_val

    response = post_ingest(client, payload)
    assert response.status_code == expected_status

    if expected_status == 400:
        metrics_data = client.get("/metrics").json()
        assert metrics_data["telemetry_ingest_rejected_total"] == 1
        assert metrics_data["telemetry_ingest_rejected_by_reason"][expected_reason] == 1


# --- 7. KIỂM THỬ XÁC THỰC TENANT HEADER ---

def test_missing_tenant_header_returns_400(client: TestClient) -> None:
    """X-Tenant-Id là bắt buộc để đảm bảo phân tách tenant."""

    response = client.post(
        "/v1/ingest",
        json=valid_payload(),
        headers={"Content-Type": "application/json", "X-Correlation-Id": "local-test-001"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "X-Tenant-Id header is required"

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["missing_tenant_header"] == 1


def test_tenant_header_body_mismatch_returns_400(client: TestClient) -> None:
    """Tenant identity trong header và body phải khớp nhau."""

    headers = tenant_headers()
    headers["X-Tenant-Id"] = "other-tenant"

    response = post_ingest(client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "X-Tenant-Id does not match body tenant_id"

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["tenant_mismatch"] == 1


# --- 8. KIỂM THỬ BẢO VỆ GHI LOG & DUNG LƯỢNG ---

def test_invalid_json_returns_400(client: TestClient) -> None:
    """JSON sai cú pháp pháp lý bị từ chối sớm và tăng invalid_json metric."""

    response = client.post(
        "/v1/ingest",
        content=b"{invalid",
        headers=tenant_headers(),
    )

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["invalid_json"] == 1


def test_invalid_payload_does_not_write_to_storage(client: TestClient, telemetry_file: Path) -> None:
    """Payload không hợp lệ tuyệt đối không được ghi vào file lưu trữ local JSONL."""

    payload = valid_payload()
    payload["ts"] = "invalid-date"

    response = post_ingest(client, payload)
    assert response.status_code == 400

    if telemetry_file.exists():
        lines = telemetry_file.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 0


def test_payload_too_large_rejection_metrics(tmp_path: Path) -> None:
    """Payload quá lớn bị từ chối 413 và tăng metric payload_too_large."""

    settings = Settings(
        local_telemetry_file=str(tmp_path / "telemetry.jsonl"),
        max_ingest_payload_bytes=32,
    )
    client = TestClient(create_app(settings))

    response = client.post("/v1/ingest", json=valid_payload(), headers=tenant_headers())
    assert response.status_code == 413
    assert response.json() == {
        "error": "payload_too_large",
        "message": "Request payload exceeds max allowed size",
        "correlation_id": "local-test-001",
    }

    metrics_data = client.get("/metrics").json()
    assert metrics_data["telemetry_ingest_rejected_total"] == 1
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["payload_too_large"] == 1


# --- 9. KIỂM THỬ CORRELATION ID VÀ HEALTH ---

def test_missing_correlation_id_auto_generates_uuid(client: TestClient) -> None:
    """Header correlation bị thiếu sẽ được thay bằng UUID tự sinh."""

    response = client.post(
        "/v1/ingest",
        json=valid_payload(),
        headers={"Content-Type": "application/json", "X-Tenant-Id": "demo-tenant-001"},
    )

    assert response.status_code == 201
    correlation_id = response.json()["correlation_id"]
    UUID(correlation_id)
    assert response.headers["X-Correlation-Id"] == correlation_id


def test_provided_correlation_id_is_preserved(client: TestClient) -> None:
    """X-Correlation-Id được gửi lên sẽ được giữ nguyên trong response."""

    response = post_ingest(client, valid_payload(), headers=tenant_headers("provided-correlation"))

    assert response.status_code == 201
    assert response.json()["correlation_id"] == "provided-correlation"
    assert response.headers["X-Correlation-Id"] == "provided-correlation"


def test_error_response_always_includes_correlation_id(client: TestClient) -> None:
    """Response ingest bị từ chối vẫn có correlation_id để trace."""

    payload = valid_payload()
    payload["metric_type"] = "not_allowed"

    response = post_ingest(client, payload, headers=tenant_headers("bad-correlation"))

    assert response.status_code == 400
    assert response.json()["correlation_id"] == "bad-correlation"


def test_health_endpoint_returns_200(client: TestClient) -> None:
    """Health endpoint trả trạng thái service và backend cơ bản."""

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "service": "telemetry-api",
        "storage_backend": "local_jsonl",
    }


def test_structured_logs_include_correlation_id(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    """Log ingest được chấp nhận chứa correlation_id của request."""

    caplog.set_level(logging.INFO, logger="telemetry_api.ingest")

    response = post_ingest(client, valid_payload(), headers=tenant_headers("log-correlation"))

    assert response.status_code == 201
    assert any("log-correlation" in record.message for record in caplog.records)
    assert any("telemetry_ingest_accepted" in record.message for record in caplog.records)
