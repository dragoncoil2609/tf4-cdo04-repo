"""Unit tests for AMP synchronous delivery, retries, and S3 failure buffering."""

from __future__ import annotations

import json
import logging
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from telemetry_api.adapters.base import DeliveryResult
from telemetry_api.adapters.s3_failure_buffer_adapter import S3FailureBufferAdapter
from telemetry_api.core.config import Settings, load_settings
from telemetry_api.core.errors import BothAMPAndS3FailedError
from telemetry_api.main import create_app
from telemetry_api.observability.metrics import get_metrics_snapshot, reset_metrics_for_tests
from telemetry_api.schemas.telemetry import TelemetryPayload


class FakeAmpDeliveryAdapter:
    """Giả lập AMP delivery với trạng thái trả về có thể lập trình."""

    def __init__(self, outcomes: list[bool], is_transient: bool = True) -> None:
        # Danh sách kết quả (True=thành công, False=thất bại) cho mỗi lần gọi
        self.outcomes = outcomes
        self.calls = 0
        self.is_transient = is_transient

    def deliver(self, payload: TelemetryPayload, event_id: str, idempotency_key: str) -> DeliveryResult:
        self.calls += 1
        if not self.outcomes:
            return DeliveryResult(success=True, status="delivered")

        success = self.outcomes.pop(0)
        if success:
            return DeliveryResult(success=True, status="delivered")
        else:
            error_code = "HTTP_500" if self.is_transient else "HTTP_400"
            return DeliveryResult(
                success=False,
                status="failed",
                error_type=error_code,
                error_message="Simulated AMP failure",
            )


class FakeS3FailureBufferAdapter:
    """Giả lập S3 failure buffer adapter."""

    def __init__(self, should_succeed: bool = True) -> None:
        self.should_succeed = should_succeed
        self.writes: list[dict] = []

    def write(
        self,
        payload: TelemetryPayload,
        event_id: str,
        correlation_id: str,
        idempotency_key: str,
        retry_count: int,
    ) -> str:
        if not self.should_succeed:
            raise RuntimeError("Simulated S3 write failure")

        self.writes.append(
            {
                "payload": payload,
                "event_id": event_id,
                "correlation_id": correlation_id,
                "idempotency_key": idempotency_key,
                "retry_count": retry_count,
            }
        )
        return f"telemetry-failures/tenant_id={payload.tenant_id}/service_id={payload.service_id}/idempotency_key={idempotency_key}.json"


@pytest.fixture()
def custom_settings() -> Settings:
    return Settings(
        env="testing",
        amp_delivery_enabled=True,
        amp_delivery_max_retries=2,
        amp_delivery_retry_base_delay_ms=1,  # delay cực nhỏ để chạy test nhanh
        amp_delivery_retry_max_delay_ms=2,
        s3_failure_buffer_enabled=True,
    )


@pytest.fixture()
def app_and_client(custom_settings: Settings):
    app = create_app(custom_settings)
    client = TestClient(app)
    # Tự động reset metrics trước khi chạy
    reset_metrics_for_tests()
    yield app, client
    reset_metrics_for_tests()


def valid_payload() -> dict[str, object]:
    return {
        "ts": "2026-06-25T10:30:00Z",
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "metric_type": "api_latency_ms",
        "value": 450.5,
        "labels": {"region": "us-east-1"},
    }


def headers(corr_id: str = "cdo-w12-020-test-001") -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "X-Tenant-Id": "demo-tenant-001",
        "X-Correlation-Id": corr_id,
    }


def test_aws_mode_forces_direct_amp_delivery_off(monkeypatch) -> None:
    monkeypatch.setenv("APP_MODE", "aws")
    monkeypatch.setenv("AMP_DELIVERY_ENABLED", "true")

    settings = load_settings()

    assert settings.app_mode == "aws"
    assert settings.amp_delivery_enabled is False


# 1. AMP SUCCESS
def test_amp_success_returns_201(app_and_client) -> None:
    app, client = app_and_client
    fake_amp = FakeAmpDeliveryAdapter([True])
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.amp_delivery_adapter = fake_amp
    app.state.s3_failure_buffer_adapter = fake_s3
    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    response = client.post("/v1/ingest", json=valid_payload(), headers=headers())

    assert response.status_code == 201
    res = response.json()
    assert res["status"] == "accepted"
    assert "event_id" in res
    assert res["correlation_id"] == "cdo-w12-020-test-001"

    # Lịch sử gọi
    assert fake_amp.calls == 1
    assert len(fake_s3.writes) == 0

    metrics = get_metrics_snapshot()
    assert metrics["telemetry_amp_delivery_attempt_total"] == 1
    assert metrics["telemetry_amp_delivery_retry_total"] == 0
    assert metrics["telemetry_ingest_buffered_total"] == 0


# 2. AMP RETRY THEN SUCCESS
def test_amp_retry_success_returns_201(app_and_client) -> None:
    app, client = app_and_client
    # Lần 1 fail, lần 2 success
    fake_amp = FakeAmpDeliveryAdapter([False, True])
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    response = client.post("/v1/ingest", json=valid_payload(), headers=headers())

    assert response.status_code == 201
    assert response.json()["status"] == "accepted"
    assert fake_amp.calls == 2
    assert len(fake_s3.writes) == 0

    metrics = get_metrics_snapshot()
    assert metrics["telemetry_amp_delivery_attempt_total"] == 1
    assert metrics["telemetry_amp_delivery_retry_total"] == 1
    assert metrics["telemetry_amp_delivery_failed_total"] == 0


# 3. AMP FAIL MAX RETRIES -> S3 BUFFER SUCCESS -> 202 ACCEPTED
def test_amp_fail_s3_success_returns_202(app_and_client) -> None:
    app, client = app_and_client
    # Thất bại liên tiếp (gọi 1 lần đầu + 2 lần retry = 3 lần fail)
    fake_amp = FakeAmpDeliveryAdapter([False, False, False])
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    response = client.post("/v1/ingest", json=valid_payload(), headers=headers())

    assert response.status_code == 202
    res = response.json()
    assert res["status"] == "buffered"
    assert res["buffer"] == "s3"
    assert "event_id" in res
    assert "idempotency_key" in res
    assert res["correlation_id"] == "cdo-w12-020-test-001"

    # Kiểm tra số lần gọi và ghi S3
    assert fake_amp.calls == 3
    assert len(fake_s3.writes) == 1
    assert fake_s3.writes[0]["event_id"] == res["event_id"]
    assert fake_s3.writes[0]["idempotency_key"] == res["idempotency_key"]
    assert fake_s3.writes[0]["retry_count"] == 2

    # Kiểm tra metrics
    metrics = get_metrics_snapshot()
    assert metrics["telemetry_amp_delivery_attempt_total"] == 1
    assert metrics["telemetry_amp_delivery_retry_total"] == 2
    assert metrics["telemetry_amp_delivery_failed_total"] == 1
    assert metrics["telemetry_s3_failure_buffer_write_total"] == 1
    assert metrics["telemetry_ingest_buffered_total"] == 1


# 4. AMP FAIL + S3 FAIL -> 503 SERVICE UNAVAILABLE
def test_amp_fail_s3_fail_returns_503(app_and_client) -> None:
    app, client = app_and_client
    fake_amp = FakeAmpDeliveryAdapter([False, False, False])
    fake_s3 = FakeS3FailureBufferAdapter(False)  # S3 ghi thất bại

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    response = client.post("/v1/ingest", json=valid_payload(), headers=headers())

    assert response.status_code == 503
    res = response.json()
    assert res["error"] == "ingest_failed"
    assert "AMP delivery failed and S3 failure buffer failed" in res["message"]
    assert "event_id" in res
    assert res["correlation_id"] == "cdo-w12-020-test-001"

    metrics = get_metrics_snapshot()
    assert metrics["telemetry_amp_delivery_failed_total"] == 1
    assert metrics["telemetry_s3_failure_buffer_failed_total"] == 1


# 5. NO RETRIES ON NON-TRANSIENT ERROR (4xx)
def test_no_retry_on_non_transient_error(app_and_client) -> None:
    app, client = app_and_client
    # Giả lập lỗi Client Error 400 (Không phải tạm thời)
    fake_amp = FakeAmpDeliveryAdapter([False], is_transient=False)
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    response = client.post("/v1/ingest", json=valid_payload(), headers=headers())

    assert response.status_code == 202
    assert fake_amp.calls == 1  # Không retry thêm lần nào

    metrics = get_metrics_snapshot()
    assert metrics["telemetry_amp_delivery_retry_total"] == 0


# 6. INVALID SCHEMAS ARE NOT BUFFERED
def test_invalid_payload_not_buffered(app_and_client) -> None:
    app, client = app_and_client
    fake_amp = FakeAmpDeliveryAdapter([False, False, False])
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    # Gửi payload thiếu trường bắt buộc
    payload = valid_payload()
    payload.pop("value")

    response = client.post("/v1/ingest", json=payload, headers=headers())
    assert response.status_code == 400
    assert fake_amp.calls == 0
    assert len(fake_s3.writes) == 0


# 7. PII PAYLOAD IS NOT BUFFERED
def test_pii_payload_not_buffered(app_and_client) -> None:
    app, client = app_and_client
    fake_amp = FakeAmpDeliveryAdapter([False, False, False])
    fake_s3 = FakeS3FailureBufferAdapter(True)

    app.state.ingest_service.amp_delivery_adapter = fake_amp
    app.state.ingest_service.s3_failure_buffer_adapter = fake_s3

    # Gửi payload chứa nhãn nhạy cảm PII
    payload = valid_payload()
    payload["labels"]["email"] = "admin@bank.com"

    response = client.post("/v1/ingest", json=payload, headers=headers())
    assert response.status_code == 400
    assert fake_amp.calls == 0
    assert len(fake_s3.writes) == 0


# 8. REPLAY SERVICE LOCAL SIMULATION TEST
def test_replay_service_local(tmp_path, monkeypatch) -> None:
    from telemetry_api.services.replay_service import ReplayService
    import os

    monkeypatch.chdir(tmp_path)

    # Tạo setup settings giả lập local
    settings = Settings(
        env="local",
        s3_failure_buffer_bucket="cdo-telemetry-failure-buffer",
        s3_failure_buffer_prefix="telemetry-failures/",
    )

    fake_amp = FakeAmpDeliveryAdapter([True])
    replay_svc = ReplayService(settings, fake_amp)

    # Viết tệp mock buffer trực tiếp vào thư mục local-store giả lập
    mock_dir = os.path.join("local-store", "s3-mock-buffer", "telemetry-failures/")
    os.makedirs(mock_dir, exist_ok=True)
    mock_file = os.path.join(mock_dir, "test_file.json")

    mock_data = {
        "event_id": "evt_test123",
        "idempotency_key": "idempotency_key_test123",
        "payload": {
            "ts": "2026-06-29T10:30:00Z",
            "tenant_id": "demo-tenant-001",
            "service_id": "payment-gateway",
            "metric_type": "api_latency_ms",
            "value": 450.5,
            "labels": {"region": "us-east-1"}
        }
    }

    with open(mock_file, "w", encoding="utf-8") as f:
        json.dump(mock_data, f)

    # Chạy replay
    count = replay_svc.replay_failures()

    assert count == 1
    assert fake_amp.calls == 1
    # Tệp mock buffer sẽ bị xóa khi gửi thành công
    assert not os.path.exists(mock_file)


def test_local_s3_buffer_write_is_replayable(tmp_path, monkeypatch) -> None:
    from telemetry_api.services.replay_service import ReplayService

    monkeypatch.chdir(tmp_path)
    settings = Settings(
        env="local",
        s3_failure_buffer_bucket="cdo-telemetry-failure-buffer",
        s3_failure_buffer_prefix="telemetry-failures/",
    )
    payload = TelemetryPayload.model_validate(valid_payload())

    buffer = S3FailureBufferAdapter(settings)
    object_key = buffer.write(
        payload=payload,
        event_id="evt-roundtrip",
        correlation_id="corr-roundtrip",
        idempotency_key="idem-roundtrip",
        retry_count=2,
    )

    assert (tmp_path / "local-store" / "s3-mock-buffer" / object_key).exists()

    fake_amp = FakeAmpDeliveryAdapter([True])
    replay_svc = ReplayService(settings, fake_amp)

    assert replay_svc.replay_failures() == 1
    assert fake_amp.calls == 1
    assert not (tmp_path / "local-store" / "s3-mock-buffer" / object_key).exists()

