"""Giao ước storage adapter cho Telemetry API."""

from __future__ import annotations

from abc import ABC, abstractmethod

from telemetry_api.schemas.telemetry import TelemetryRecord


class TelemetryStorageAdapter(ABC):
    """Giao diện cho các backend lưu trữ telemetry."""

    @abstractmethod
    def store(self, record: TelemetryRecord) -> None:
        """Lưu hoặc forward một telemetry record đã validate."""


from dataclasses import dataclass
from typing import Protocol
from telemetry_api.schemas.telemetry import TelemetryPayload


@dataclass
class DeliveryResult:
    success: bool
    status: str
    error_type: str | None = None
    error_message: str | None = None


class TelemetryDeliveryAdapter(Protocol):
    """Giao ước delivery adapter gửi telemetry tới AMP."""

    def deliver(self, payload: TelemetryPayload, event_id: str, idempotency_key: str) -> DeliveryResult:
        """Thực hiện gửi telemetry đồng bộ tới AMP."""
        ...

