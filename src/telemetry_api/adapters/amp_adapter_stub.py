"""Điểm tích hợp adapter AMP remote_write trong tương lai."""

from __future__ import annotations

from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.schemas.telemetry import TelemetryRecord


class AmpTelemetryAdapter(TelemetryStorageAdapter):
    """Lớp giữ chỗ cho luồng ghi Amazon Managed Service for Prometheus sau này.

    Class này cố ý chưa gọi AWS ở thời điểm hiện tại. Route và service layer
    có thể giữ nguyên khi implementation AMP remote_write thật được thêm vào đây.
    """

    def store(self, record: TelemetryRecord) -> None:
        """Báo lỗi rõ ràng vì luồng ghi AMP thật chưa được triển khai."""

        raise NotImplementedError("AMP telemetry adapter is not implemented yet")
