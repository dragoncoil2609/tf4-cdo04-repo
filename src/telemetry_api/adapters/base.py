"""Giao ước storage adapter cho Telemetry API."""

from __future__ import annotations

from abc import ABC, abstractmethod

from telemetry_api.schemas.telemetry import TelemetryRecord


class TelemetryStorageAdapter(ABC):
    """Giao diện cho các backend lưu trữ telemetry."""

    @abstractmethod
    def store(self, record: TelemetryRecord) -> None:
        """Lưu hoặc forward một telemetry record đã validate."""
