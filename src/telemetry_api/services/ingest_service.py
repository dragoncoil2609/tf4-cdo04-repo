"""Tầng service để kiểm tra hợp lệ và lưu telemetry ingest record."""

from __future__ import annotations

from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.core.logging import now_utc_iso
from telemetry_api.schemas.telemetry import TelemetryPayload, TelemetryRecord
from telemetry_api.core.errors import BadRequestError


class IngestService:
    """Điều phối kiểm tra tenant, tạo record và ghi xuống storage."""

    def __init__(self, storage_adapter: TelemetryStorageAdapter) -> None:
        self.storage_adapter = storage_adapter

    def ingest(
        self,
        payload: TelemetryPayload,
        header_tenant_id: str,
        correlation_id: str,
    ) -> TelemetryRecord:
        """Nhận một telemetry payload và lưu qua adapter đã cấu hình."""

        validate_tenant_match(header_tenant_id, payload.tenant_id)
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
        self.storage_adapter.store(record)
        return record


def validate_tenant_match(header_tenant_id: str, body_tenant_id: str) -> None:
    """Đảm bảo tenant trong request header khớp với tenant trong body."""

    if header_tenant_id != body_tenant_id:
        raise BadRequestError("X-Tenant-Id does not match body tenant_id")
