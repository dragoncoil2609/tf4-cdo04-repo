"""Kiểm thử endpoint POST /v1/ingest."""

from __future__ import annotations

import json
import logging
from pathlib import Path
from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from telemetry_api.core.config import Settings
from telemetry_api.main import create_app


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


@pytest.mark.parametrize("missing_field", ["tenant_id", "service_id", "metric_type", "ts", "value"])
def test_missing_required_fields_return_400(client: TestClient, missing_field: str) -> None:
    """Mỗi field body bắt buộc đều trả HTTP 400 khi bị thiếu."""

    payload = valid_payload()
    payload.pop(missing_field)

    response = post_ingest(client, payload)

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert response.json()["correlation_id"] == "local-test-001"


def test_missing_tenant_header_returns_400(client: TestClient) -> None:
    """X-Tenant-Id là bắt buộc để đảm bảo tenant isolation."""

    response = client.post(
        "/v1/ingest",
        json=valid_payload(),
        headers={"Content-Type": "application/json", "X-Correlation-Id": "local-test-001"},
    )

    assert response.status_code == 400
    assert response.json()["message"] == "X-Tenant-Id header is required"


def test_tenant_header_body_mismatch_returns_400(client: TestClient) -> None:
    """Tenant identity trong header và body phải khớp nhau."""

    headers = tenant_headers()
    headers["X-Tenant-Id"] = "other-tenant"

    response = post_ingest(client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "X-Tenant-Id does not match body tenant_id"


def test_invalid_json_returns_400(client: TestClient) -> None:
    """JSON sai định dạng trả response 400 theo yêu cầu task."""

    response = client.post(
        "/v1/ingest",
        content=b"{invalid",
        headers=tenant_headers(),
    )

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert response.json()["correlation_id"] == "local-test-001"


def test_unsupported_metric_type_returns_400(client: TestClient) -> None:
    """Metric type phải nằm trong allowlist của telemetry contract đã freeze."""

    payload = valid_payload()
    payload["metric_type"] = "unknown_metric"

    response = post_ingest(client, payload)

    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"


def test_invalid_timestamp_returns_400(client: TestClient) -> None:
    """Timestamp phải là RFC3339 UTC với hậu tố Z."""

    payload = valid_payload()
    payload["ts"] = "2026-06-25 10:30:00"

    response = post_ingest(client, payload)

    assert response.status_code == 400


def test_non_number_value_returns_400(client: TestClient) -> None:
    """Giá trị metric phải là JSON number."""

    payload = valid_payload()
    payload["value"] = "450.5"

    response = post_ingest(client, payload)

    assert response.status_code == 400


def test_invalid_labels_type_returns_400(client: TestClient) -> None:
    """Labels nếu có phải là JSON object."""

    payload = valid_payload()
    payload["labels"] = ["region", "us-east-1"]

    response = post_ingest(client, payload)

    assert response.status_code == 400


def test_high_cardinality_label_returns_400(client: TestClient) -> None:
    """Label key high-cardinality bị reject trước khi lưu."""

    payload = valid_payload()
    payload["labels"] = {"request_id": "req-123"}

    response = post_ingest(client, payload)

    assert response.status_code == 400


def test_sensitive_label_returns_400(client: TestClient) -> None:
    """Label key nhạy cảm bị reject trước khi lưu."""

    payload = valid_payload()
    payload["labels"] = {"token": "abc"}

    response = post_ingest(client, payload)

    assert response.status_code == 400


def test_payload_too_large_returns_413(tmp_path: Path) -> None:
    """Payload quá lớn bị reject trước khi validate JSON."""

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
