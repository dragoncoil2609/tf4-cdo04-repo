"""Điểm tích hợp adapter AMP remote_write trong tương lai."""

from __future__ import annotations

from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.schemas.telemetry import TelemetryRecord


class AmpTelemetryAdapter(TelemetryStorageAdapter):
    """Lớp giữ chỗ/no-op cho luồng ghi Amazon Managed Service for Prometheus.

    Trong AWS mode, dữ liệu telemetry hợp lệ được lưu giữ trong bộ nhớ Prometheus Exporter
    và được scrape bất đồng bộ từ endpoint /metrics bởi ADOT Collector để remote_write.
    """

    def store(self, record: TelemetryRecord) -> None:
        """Trong AWS mode, việc lưu trữ trực tiếp là no-op."""
        pass

