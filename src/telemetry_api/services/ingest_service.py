"""Tầng service để kiểm tra hợp lệ và lưu telemetry ingest record."""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from typing import TYPE_CHECKING

from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.core.errors import BadRequestError, BothAMPAndS3FailedError
from telemetry_api.core.idempotency import generate_idempotency_key
from telemetry_api.core.logging import now_utc_iso
from telemetry_api.core.retry import execute_with_retry
from telemetry_api.observability.metrics import (
    record_amp_delivery_attempt,
    record_amp_delivery_failed,
    record_amp_delivery_retry,
    record_ingest_buffered,
    record_s3_failure_buffer_failed,
    record_s3_failure_buffer_write,
)
from telemetry_api.schemas.telemetry import TelemetryPayload, TelemetryRecord

if TYPE_CHECKING:
    from telemetry_api.adapters.amp_delivery_adapter import AmpDeliveryAdapter
    from telemetry_api.adapters.s3_failure_buffer_adapter import S3FailureBufferAdapter
    from telemetry_api.core.config import Settings
    from telemetry_api.observability.prometheus_exporter import PrometheusTelemetryExporter

logger = logging.getLogger("telemetry_api.ingest_service")


@dataclass
class IngestResult:
    """Kết quả trả về sau khi ingest telemetry."""

    status: str  # "accepted" hoặc "buffered"
    event_id: str
    idempotency_key: str
    record: TelemetryRecord


class IngestService:
    """Điều phối kiểm tra tenant, tạo record và ghi xuống storage/AMP/S3."""

    def __init__(
        self,
        storage_adapter: TelemetryStorageAdapter,
        prometheus_exporter: PrometheusTelemetryExporter | None = None,
        amp_delivery_adapter: AmpDeliveryAdapter | None = None,
        s3_failure_buffer_adapter: S3FailureBufferAdapter | None = None,
        settings: Settings | None = None,
    ) -> None:
        self.storage_adapter = storage_adapter
        self.prometheus_exporter = prometheus_exporter
        self.amp_delivery_adapter = amp_delivery_adapter
        self.s3_failure_buffer_adapter = s3_failure_buffer_adapter
        self.settings = settings

    def ingest(
        self,
        payload: TelemetryPayload,
        header_tenant_id: str,
        correlation_id: str,
    ) -> IngestResult:
        """Nhận một telemetry payload, thực hiện validate và gửi đi/buffer."""

        validate_tenant_match(header_tenant_id, payload.tenant_id)

        # 1. Khởi tạo event_id và idempotency_key
        event_id = f"evt_{uuid.uuid4().hex[:12]}"
        idempotency_key = generate_idempotency_key(payload)

        record = TelemetryRecord(
            correlation_id=correlation_id,
            received_at=now_utc_iso(),
            ts=payload.ts,
            tenant_id=payload.tenant_id,
            service_id=payload.service_id,
            metric_type=payload.metric_type,
            value=payload.value,
            labels=payload.labels or {},
        )

        # Ghi nhận log lưu local (local persistence)
        self.storage_adapter.store(record)

        if self.prometheus_exporter is not None:
            self.prometheus_exporter.observe(payload)

        # 2. Xử lý gửi đồng bộ tới AMP (nếu bật)
        amp_enabled = True
        max_retries = 3
        base_delay_ms = 500
        max_delay_ms = 5000

        if self.settings is not None:
            amp_enabled = self.settings.amp_delivery_enabled
            max_retries = self.settings.amp_delivery_max_retries
            base_delay_ms = self.settings.amp_delivery_retry_base_delay_ms
            max_delay_ms = self.settings.amp_delivery_retry_max_delay_ms

        delivery_success = True

        if amp_enabled and self.amp_delivery_adapter is not None:
            # Ghi nhận metric nỗ lực gửi
            record_amp_delivery_attempt()
            if self.prometheus_exporter is not None:
                self.prometheus_exporter.record_amp_delivery_attempt()

            def attempt_delivery():
                return self.amp_delivery_adapter.deliver(payload, event_id, idempotency_key)

            def on_retry(attempt_num, err_type, err_msg):
                record_amp_delivery_retry()
                if self.prometheus_exporter is not None:
                    self.prometheus_exporter.record_amp_delivery_retry()
                # Log structured event
                from telemetry_api.core.logging import log_structured
                log_structured(
                    logger,
                    logging.WARNING,
                    "amp_delivery_retry",
                    event_id=event_id,
                    correlation_id=correlation_id,
                    attempt=attempt_num,
                    max_retries=max_retries,
                    error_type=err_type,
                )

            # Thực hiện retry
            result = execute_with_retry(
                attempt_delivery,
                max_retries=max_retries,
                base_delay_ms=base_delay_ms,
                max_delay_ms=max_delay_ms,
                on_retry_callback=on_retry,
            )

            if not result.success:
                delivery_success = False
                record_amp_delivery_failed()
                if self.prometheus_exporter is not None:
                    self.prometheus_exporter.record_amp_delivery_failed()

                from telemetry_api.core.logging import log_structured
                log_structured(
                    logger,
                    logging.ERROR,
                    "amp_delivery_failed_after_retry",
                    event_id=event_id,
                    correlation_id=correlation_id,
                    error_type=result.error_type,
                )

        if delivery_success:
            return IngestResult(
                status="accepted",
                event_id=event_id,
                idempotency_key=idempotency_key,
                record=record,
            )

        # 3. Chuyển sang lưu S3 failure buffer nếu gửi AMP thất bại
        s3_enabled = True
        if self.settings is not None:
            s3_enabled = self.settings.s3_failure_buffer_enabled

        if s3_enabled and self.s3_failure_buffer_adapter is not None:
            try:
                object_key = self.s3_failure_buffer_adapter.write(
                    payload=payload,
                    event_id=event_id,
                    correlation_id=correlation_id,
                    idempotency_key=idempotency_key,
                    retry_count=max_retries,
                )
                # Ghi nhận metric buffer thành công
                record_s3_failure_buffer_write()
                record_ingest_buffered()
                if self.prometheus_exporter is not None:
                    self.prometheus_exporter.record_s3_failure_buffer_write()
                    self.prometheus_exporter.record_ingest_buffered()

                from telemetry_api.core.logging import log_structured
                log_structured(
                    logger,
                    logging.INFO,
                    "s3_failure_buffer_write_success",
                    event_id=event_id,
                    correlation_id=correlation_id,
                    idempotency_key=idempotency_key,
                    bucket=self.settings.s3_failure_buffer_bucket if self.settings else "cdo-telemetry-failure-buffer",
                    object_key=object_key,
                )

                return IngestResult(
                    status="buffered",
                    event_id=event_id,
                    idempotency_key=idempotency_key,
                    record=record,
                )
            except Exception as exc:
                record_s3_failure_buffer_failed()
                if self.prometheus_exporter is not None:
                    self.prometheus_exporter.record_s3_failure_buffer_failed()

                from telemetry_api.core.logging import log_structured
                log_structured(
                    logger,
                    logging.ERROR,
                    "s3_failure_buffer_write_failed",
                    event_id=event_id,
                    correlation_id=correlation_id,
                    error_type=type(exc).__name__,
                )
                raise BothAMPAndS3FailedError(
                    event_id=event_id,
                    message=f"AMP delivery failed and S3 failure buffer failed: {exc}",
                )
        else:
            raise BothAMPAndS3FailedError(
                event_id=event_id,
                message="AMP delivery failed and S3 failure buffer is disabled/unavailable",
            )


def validate_tenant_match(header_tenant_id: str, body_tenant_id: str) -> None:
    """Đảm bảo tenant trong request header khớp với tenant trong body."""

    if header_tenant_id != body_tenant_id:
        raise BadRequestError("X-Tenant-Id does not match body tenant_id")
