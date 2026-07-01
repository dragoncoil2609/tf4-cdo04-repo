"""Kiểm thử endpoint POST /v1/ingest và các quy tắc Schema Validation + PII & Cardinality Denylist + Metric Allowlist."""

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


# --- 1. KIỂM THỬ PAYLOAD HỢP LỆ VÀ GHI FILE (CDO-W12-015) ---

def test_valid_payload_returns_201_and_writes_jsonl(client: TestClient, telemetry_file: Path) -> None:
    """Datapoint telemetry hợp lệ được chấp nhận và ghi nối tiếp vào JSONL local."""

    response = post_ingest(client, valid_payload())

    assert response.status_code == 201
    res = response.json()
    assert res["status"] == "accepted"
    assert res["correlation_id"] == "local-test-001"
    assert res["tenant_id"] == "demo-tenant-001"
    assert res["service_id"] == "payment-gateway"
    assert res["metric_type"] == "api_latency_ms"
    assert "event_id" in res
    assert "request_id" in res

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
    """Kiểm tra giá trị ban đầu của /debug/metrics-json khi chưa có request."""

    response = client.get("/debug/metrics-json")
    assert response.status_code == 200
    data = response.json()
    assert data["telemetry_ingest_accepted_total"] == 0
    assert data["telemetry_ingest_rejected_total"] == 0
    assert data["telemetry_ingest_rejected_by_reason"] == {}


def test_accepted_request_increments_metric(client: TestClient) -> None:
    """Request thành công sẽ tăng bộ đếm accepted lên 1."""

    response = post_ingest(client, valid_payload())
    assert response.status_code == 201

    metrics_resp = client.get("/debug/metrics-json")
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
    metrics_data = client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_total"] == 1
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["missing_required_field"] == 1


# --- 3. KIỂM THỬ VALIDATE TIMESTAMP (ts) (CDO-W12-016) ---

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
        metrics_data = client.get("/debug/metrics-json").json()
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
        metrics_data = client.get("/debug/metrics-json").json()
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

    metrics_data = client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_total"] == 1
    assert metrics_data["telemetry_ingest_rejected_by_reason"][expected_reason] == 1


# --- 6. KIỂM THỬ VALIDATE LABELS ĐƠN GIẢN & AN TOÀN ---

@pytest.mark.parametrize("labels_val, expected_status, expected_reason", [
    (None, 400, "missing_required_label"),
    ({}, 400, "missing_required_label"),
    ({"region": "us-east-1", "env": "local", "status": True, "code": 200, "empty": None}, 201, None),
    ("region=us-east-1", 400, "invalid_labels_type"),
    (["region", "us-east-1"], 400, "invalid_labels_type"),
    ({"region": {"name": "us-east-1"}}, 400, "nested_label_object"),
    ({"regions": ["us-east-1"]}, 400, "nested_label_object"),
    ({"region": "us-east-1", "request_id": "req-123"}, 400, "pii_denylist_label"),  # request_id thuộc PII và high cardinality
    ({"region": "us-east-1", "token": "abc"}, 400, "pii_denylist_label"),
    ({"region": "us-east-1", "my_label": "my-secret-password"}, 400, "pii_denylist_label"),
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
        metrics_data = client.get("/debug/metrics-json").json()
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

    metrics_data = client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["missing_tenant_header"] == 1


def test_tenant_header_body_mismatch_returns_400(client: TestClient) -> None:
    """Tenant identity trong header và body phải khớp nhau."""

    headers = tenant_headers()
    headers["X-Tenant-Id"] = "other-tenant"

    response = post_ingest(client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "X-Tenant-Id does not match body tenant_id"

    metrics_data = client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["tenant_mismatch"] == 1


def test_ingest_token_unset_keeps_local_auth_optional(client: TestClient) -> None:
    """Local mode không cấu hình token vẫn nhận request không có Authorization."""

    response = post_ingest(client, valid_payload())

    assert response.status_code == 201


def test_ingest_token_configured_requires_authorization(telemetry_file: Path) -> None:
    """Khi TENANT_INGEST_TOKEN được inject, thiếu Authorization bị từ chối."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))

    response = post_ingest(token_client, valid_payload())

    assert response.status_code == 400
    assert response.json()["message"] == "Invalid or missing ingest token"
    metrics_data = token_client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["invalid_ingest_token"] == 1


def test_ingest_token_configured_rejects_wrong_bearer(telemetry_file: Path) -> None:
    """Bearer token sai bị từ chối."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))
    headers = tenant_headers()
    headers["Authorization"] = "Bearer wrong-token"

    response = post_ingest(token_client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "Invalid or missing ingest token"
    metrics_data = token_client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["invalid_ingest_token"] == 1


def test_ingest_token_configured_accepts_correct_bearer(telemetry_file: Path) -> None:
    """Bearer token đúng được chấp nhận."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))
    headers = tenant_headers()
    headers["Authorization"] = "Bearer secret-token"

    response = post_ingest(token_client, valid_payload(), headers=headers)

    assert response.status_code == 201


def test_tenant_ingest_token_header_accepted_when_configured(telemetry_file: Path) -> None:
    """X-Tenant-Ingest-Token đúng được ưu tiên hơn Authorization: Bearer."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))
    headers = tenant_headers()
    headers["X-Tenant-Ingest-Token"] = "secret-token"

    response = post_ingest(token_client, valid_payload(), headers=headers)

    assert response.status_code == 201
    metrics_data = token_client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_accepted_total"] == 1


def test_tenant_ingest_token_header_wrong_rejected(telemetry_file: Path) -> None:
    """X-Tenant-Ingest-Token sai bị từ chối 400."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))
    headers = tenant_headers()
    headers["X-Tenant-Ingest-Token"] = "wrong-token"

    response = post_ingest(token_client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "Invalid or missing ingest token"
    metrics_data = token_client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["invalid_ingest_token"] == 1


def test_tenant_ingest_token_header_wins_over_wrong_bearer(telemetry_file: Path) -> None:
    """Khi có cả X-Tenant-Ingest-Token sai và Authorization Bearer đúng, header mới wins -> bị từ chối."""

    settings = Settings(local_telemetry_file=str(telemetry_file), tenant_ingest_token="secret-token")
    token_client = TestClient(create_app(settings))
    headers = tenant_headers()
    headers["X-Tenant-Ingest-Token"] = "wrong-token"
    headers["Authorization"] = "Bearer secret-token"

    response = post_ingest(token_client, valid_payload(), headers=headers)

    assert response.status_code == 400
    assert response.json()["message"] == "Invalid or missing ingest token"
    metrics_data = token_client.get("/debug/metrics-json").json()
    assert metrics_data["telemetry_ingest_rejected_by_reason"]["invalid_ingest_token"] == 1


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

    metrics_data = client.get("/debug/metrics-json").json()
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

    metrics_data = client.get("/debug/metrics-json").json()
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
    payload["labels"] = {"region": "us-east-1", "email": "user@example.com"}

    response = post_ingest(client, payload, headers=tenant_headers("bad-correlation"))

    assert response.status_code == 400
    assert response.json()["correlation_id"] == "bad-correlation"


def test_health_endpoint_returns_200(client: TestClient) -> None:
    """Health endpoint trả trạng thái service và metadata tối giản an toàn."""

    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "telemetry-api"
    assert body["version"] == "0.1.0"
    assert "build_id" in body or "commit_sha" in body
    assert body["environment"] == "local"


def test_health_does_not_leak_secrets(client: TestClient) -> None:
    """Đảm bảo /health tuyệt đối không rò rỉ bất kỳ thông tin nhạy cảm hay bí mật nào."""

    response = client.get("/health")
    body_text = response.text.lower()

    forbidden_terms = [
        "secret",
        "token",
        "password",
        "authorization",
        "aws_secret_access_key",
        "database_url",
        "api_key",
    ]

    for term in forbidden_terms:
        assert term not in body_text


def test_health_does_not_mutate_storage(client: TestClient, telemetry_file: Path) -> None:
    """Gọi /health tuyệt đối không ghi file hay gọi storage adapter."""

    response = client.get("/health")
    assert response.status_code == 200

    if telemetry_file.exists():
        assert telemetry_file.read_text(encoding="utf-8") == ""


def test_structured_logs_include_correlation_id(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    """Log ingest được chấp nhận chứa correlation_id của request."""

    caplog.set_level(logging.INFO, logger="telemetry_api.ingest")

    response = post_ingest(client, valid_payload(), headers=tenant_headers("log-correlation"))

    assert response.status_code == 201
    assert any("log-correlation" in record.message for record in caplog.records)
    assert any("telemetry_ingest_accepted" in record.message for record in caplog.records)


# --- 10. KIỂM THỬ PHÁT HIỆN PII & CARDINALITY DENYLIST (CDO-W12-017) ---

def test_valid_safe_labels_success(client: TestClient, telemetry_file: Path) -> None:
    """Kiểm tra các label an toàn được chấp nhận 201 và ghi file."""

    payload = valid_payload()
    payload["labels"] = {
        "region": "us-east-1",
        "env": "local",
        "service_tier": "tier-1",
        "db_type": "postgres",
        "queue_name": "prediction-queue",
        "cache_type": "redis",
        "source": "api_gateway",
        "aws_namespace": "ForesightLens",
    }
    response = post_ingest(client, payload)
    assert response.status_code == 201

    lines = telemetry_file.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 1
    stored = json.loads(lines[0])
    assert stored["labels"]["region"] == "us-east-1"
    assert stored["labels"]["env"] == "local"


@pytest.mark.parametrize("denied_key", [
    "email",
    "phone",
    "name",
    "transaction_id",
    "account_id",
    "card_pan",
    "user_id",
    "request_id",
    "trace_id",
    "prediction_id",
])
def test_pii_denylist_keys(client: TestClient, denied_key: str) -> None:
    """Kiểm tra từng key trong denylist của PII đều bị từ chối 400."""

    payload = valid_payload()
    payload["labels"] = {"region": "us-east-1", denied_key: "value"}
    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert "denied by PII policy" in response.json()["message"]

    # Kể cả viết hoa/thường lẫn lộn
    payload_upper = valid_payload()
    payload_upper["labels"] = {"region": "us-east-1", denied_key.upper(): "value"}
    response_upper = post_ingest(client, payload_upper)
    assert response_upper.status_code == 400
    assert response_upper.json()["error"] == "bad_request"


@pytest.mark.parametrize("cardinality_key", [
    "session_id",
    "raw_path",
])
def test_high_cardinality_keys(client: TestClient, cardinality_key: str) -> None:
    """Kiểm tra các key có cardinality cao bị từ chối 400."""

    payload = valid_payload()
    payload["labels"] = {"region": "us-east-1", cardinality_key: "value"}
    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert "denied by high-cardinality policy" in response.json()["message"]


@pytest.mark.parametrize("raw_path_val", [
    "/users/12345/orders/98765",
    "/accounts/acc_123/transactions/txn_999",
    "/payment/transaction/abc-123-def",
    "/api/v1/users/550e8400-e29b-41d4-a716-446655440000",
])
def test_raw_path_with_ids_values(client: TestClient, raw_path_val: str) -> None:
    """Kiểm tra các giá trị path chứa dynamic ID bị từ chối 400."""

    payload = valid_payload()
    payload["labels"] = {"region": "us-east-1", "path": raw_path_val}
    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert "looks like raw endpoint path with IDs" in response.json()["message"]


def test_pii_and_cardinality_rejection_storage_protection(client: TestClient, telemetry_file: Path) -> None:
    """Các request bị PII và cardinality rejection tuyệt đối không được ghi vào file lưu trữ."""

    # 1. Gửi request bị PII reject
    payload1 = valid_payload()
    payload1["labels"] = {"region": "us-east-1", "email": "user@example.com"}
    response1 = post_ingest(client, payload1)
    assert response1.status_code == 400

    # 2. Gửi request bị cardinality reject
    payload2 = valid_payload()
    payload2["labels"] = {"region": "us-east-1", "session_id": "session-12345"}
    response2 = post_ingest(client, payload2)
    assert response2.status_code == 400

    # 3. File local-store phải không tồn tại hoặc hoàn toàn rỗng
    if telemetry_file.exists():
        assert telemetry_file.read_text(encoding="utf-8") == ""


def test_pii_and_cardinality_metrics_increments(client: TestClient) -> None:
    """Kiểm tra PII và Cardinality rejection tăng đúng các bộ đếm metrics chuyên biệt."""

    # Ban đầu
    m0 = client.get("/debug/metrics-json").json()
    assert m0["telemetry_ingest_pii_rejected_total"] == 0
    assert m0["telemetry_ingest_cardinality_rejected_total"] == 0

    # 1. Gây lỗi PII
    payload1 = valid_payload()
    payload1["labels"] = {"region": "us-east-1", "email": "user@example.com"}
    post_ingest(client, payload1)

    m1 = client.get("/debug/metrics-json").json()
    assert m1["telemetry_ingest_pii_rejected_total"] == 1
    assert m1["telemetry_ingest_cardinality_rejected_total"] == 0
    assert m1["telemetry_ingest_rejected_by_reason"]["pii_denylist_label"] == 1

    # 2. Gây lỗi cardinality
    payload2 = valid_payload()
    payload2["labels"] = {"region": "us-east-1", "session_id": "session-12345"}
    post_ingest(client, payload2)

    # 3. Gây lỗi raw path with IDs
    payload3 = valid_payload()
    payload3["labels"] = {"region": "us-east-1", "path": "/users/123/orders"}
    post_ingest(client, payload3)

    m2 = client.get("/debug/metrics-json").json()
    assert m2["telemetry_ingest_pii_rejected_total"] == 1
    assert m2["telemetry_ingest_cardinality_rejected_total"] == 2
    assert m2["telemetry_ingest_rejected_by_reason"]["high_cardinality_label"] == 1
    assert m2["telemetry_ingest_rejected_by_reason"]["raw_endpoint_path_with_ids"] == 1
    assert m2["telemetry_ingest_rejected_total"] == 3


def test_pii_denylist_logging_and_response_no_leak(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    """Kiểm tra log và response của PII rejection không được rò rỉ dữ liệu nhạy cảm."""

    caplog.set_level(logging.WARNING, logger="telemetry_api.ingest")

    payload = valid_payload()
    payload["labels"] = {"region": "us-east-1", "email": "sensitive-user-email@domain.com"}

    response = post_ingest(client, payload, headers=tenant_headers("leak-test-001"))

    assert response.status_code == 400
    res_data = response.json()
    assert res_data["correlation_id"] == "leak-test-001"
    # Response message không được chứa email thực tế
    assert "sensitive-user-email@domain.com" not in res_data["message"]
    assert "email" in res_data["message"]

    # Log không được chứa email thực tế nhưng phải có correlation_id, reason, denied_key
    log_messages = [record.message for record in caplog.records]
    assert any("leak-test-001" in msg for msg in log_messages)
    assert any("pii_denylist_label" in msg for msg in log_messages)
    assert any("email" in msg for msg in log_messages)
    assert not any("sensitive-user-email@domain.com" in msg for msg in log_messages)


def test_raw_path_with_ids_logging_and_response_no_leak(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    """Kiểm tra log và response của raw path with IDs không rò rỉ path thực tế."""

    caplog.set_level(logging.WARNING, logger="telemetry_api.ingest")

    payload = valid_payload()
    payload["labels"] = {"region": "us-east-1", "path": "/api/v1/users/550e8400-e29b-41d4-a716-446655440000"}

    response = post_ingest(client, payload, headers=tenant_headers("path-test-002"))

    assert response.status_code == 400
    res_data = response.json()
    assert res_data["correlation_id"] == "path-test-002"
    assert "/api/v1/users/550e8400-e29b-41d4-a716-446655440000" not in res_data["message"]

    log_messages = [record.message for record in caplog.records]
    assert any("path-test-002" in msg for msg in log_messages)
    assert any("raw_endpoint_path_with_ids" in msg for msg in log_messages)
    assert any("path" in msg for msg in log_messages)
    assert not any("550e8400-e29b-41d4-a716-446655440000" in msg for msg in log_messages)


# --- 11. KIỂM THỬ CHÍNH SÁCH METRIC ALLOWLIST & LABELS BẮT BUỘC (CDO-W12-018) ---

@pytest.mark.parametrize("metric_type, labels", [
    ("cpu_usage_percent", {"region": "us-east-1"}),
    ("memory_usage_percent", {"region": "us-east-1"}),
    ("active_connections", {"region": "us-east-1"}),
    ("db_connection_pool_pct", {"region": "us-east-1", "db_type": "postgres"}),
    ("queue_depth", {"region": "us-east-1", "queue_name": "kyc-processing"}),
    ("cache_hit_rate_pct", {"region": "us-east-1", "cache_type": "redis"}),
    ("api_latency_ms", {"region": "us-east-1"}),
])
def test_allowlisted_metrics_success(client: TestClient, metric_type: str, labels: dict[str, Any]) -> None:
    """Đảm bảo cả 7 AI signals trong contract đều được chấp nhận khi có đủ nhãn bắt buộc."""

    payload = valid_payload()
    payload["metric_type"] = metric_type
    payload["labels"] = labels

    response = post_ingest(client, payload)
    assert response.status_code == 201
    assert response.json()["status"] == "accepted"


@pytest.mark.parametrize("unsupported_metric", [
    "random_metric",
    "latency",
    "business_revenue",
])
def test_unsupported_metrics_rejected(client: TestClient, unsupported_metric: str) -> None:
    """Các metric ngoài allowlist phải bị từ chối 400 với lý do unsupported_metric_type."""

    payload = valid_payload()
    payload["metric_type"] = unsupported_metric

    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert "not in AI signal allowlist" in response.json()["message"]

    # Đảm bảo ghi nhận metrics
    m = client.get("/debug/metrics-json").json()
    assert m["telemetry_ingest_unsupported_metric_rejected_total"] == 1
    assert m["telemetry_ingest_rejected_by_reason"]["unsupported_metric_type"] == 1


@pytest.mark.parametrize("internal_metric", [
    "error_rate",
    "oldest_message_age_seconds",
])
def test_internal_only_metrics_rejected(client: TestClient, internal_metric: str) -> None:
    """Các metric dùng nội bộ (internal-only) phải bị chặn, không làm AI signal."""

    payload = valid_payload()
    payload["metric_type"] = internal_metric

    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert response.json()["error"] == "bad_request"
    assert "is internal-only and must not be sent as AI signal" in response.json()["message"]

    # Đảm bảo ghi nhận metrics
    m = client.get("/debug/metrics-json").json()
    assert m["telemetry_ingest_internal_only_metric_rejected_total"] == 1
    assert m["telemetry_ingest_rejected_by_reason"]["internal_only_metric_not_ai_signal"] == 1


@pytest.mark.parametrize("metric_type, labels, missing_label", [
    ("queue_depth", {"region": "us-east-1"}, "queue_name"),
    ("db_connection_pool_pct", {"region": "us-east-1"}, "db_type"),
    ("cache_hit_rate_pct", {"region": "us-east-1"}, "cache_type"),
    ("cpu_usage_percent", {}, "region"),
])
def test_missing_required_labels(client: TestClient, metric_type: str, labels: dict[str, Any], missing_label: str) -> None:
    """Thiếu nhãn bắt buộc theo đặc tả của metric phải bị từ chối 400."""

    payload = valid_payload()
    payload["metric_type"] = metric_type
    payload["labels"] = labels

    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert f"requires label: {missing_label}" in response.json()["message"]

    # Đảm bảo ghi nhận metrics
    m = client.get("/debug/metrics-json").json()
    assert m["telemetry_ingest_metric_label_rejected_total"] == 1
    assert m["telemetry_ingest_rejected_by_reason"]["missing_required_label"] == 1


@pytest.mark.parametrize("empty_val", ["", "   "])
def test_required_label_empty_or_whitespace(client: TestClient, empty_val: str) -> None:
    """Nhãn bắt buộc không được là chuỗi rỗng hoặc chỉ toàn khoảng trắng."""

    payload = valid_payload()
    payload["metric_type"] = "queue_depth"
    payload["labels"] = {"region": "us-east-1", "queue_name": empty_val}

    response = post_ingest(client, payload)
    assert response.status_code == 400
    assert "cannot be empty" in response.json()["message"]

    # Đảm bảo ghi nhận metrics
    m = client.get("/debug/metrics-json").json()
    assert m["telemetry_ingest_metric_label_rejected_total"] == 1
    assert m["telemetry_ingest_rejected_by_reason"]["empty_required_label"] == 1


def test_metric_rejections_do_not_write_to_storage(client: TestClient, telemetry_file: Path) -> None:
    """Các request bị chặn do chính sách metric/nhãn tuyệt đối không ghi file."""

    # 1. Unsupported metric
    p1 = valid_payload()
    p1["metric_type"] = "random_metric"
    post_ingest(client, p1)

    # 2. Internal-only metric
    p2 = valid_payload()
    p2["metric_type"] = "error_rate"
    post_ingest(client, p2)

    # 3. Missing label
    p3 = valid_payload()
    p3["metric_type"] = "queue_depth"
    p3["labels"] = {"region": "us-east-1"}
    post_ingest(client, p3)

    if telemetry_file.exists():
        assert telemetry_file.read_text(encoding="utf-8") == ""


def test_metric_rejection_logging_structured(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    """Kiểm tra logs ghi nhận đầy đủ lý do từ chối metric/labels và correlation_id."""

    caplog.set_level(logging.WARNING, logger="telemetry_api.ingest")

    # Gửi thiếu nhãn bắt buộc
    payload = valid_payload()
    payload["metric_type"] = "queue_depth"
    payload["labels"] = {"region": "us-east-1"}

    response = post_ingest(client, payload, headers=tenant_headers("metric-log-test"))
    assert response.status_code == 400

    log_messages = [record.message for record in caplog.records]
    assert any("metric-log-test" in msg for msg in log_messages)
    assert any("missing_required_label" in msg for msg in log_messages)
    assert any("queue_name" in msg for msg in log_messages)
