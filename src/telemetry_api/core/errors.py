"""Các loại lỗi và helper response cho Telemetry API."""

from __future__ import annotations


class TelemetryApiError(Exception):
    """Exception nền có thể ánh xạ trực tiếp sang JSON response an toàn."""

    def __init__(
        self,
        status_code: int,
        error: str,
        message: str,
        reason: str = "internal_error",
        denied_key: str | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error = error
        self.message = message
        self.reason = reason
        self.denied_key = denied_key


class BadRequestError(TelemetryApiError):
    """Được raise khi request không qua validation và cần trả HTTP 400."""

    def __init__(self, message: str, reason: str = "bad_request", denied_key: str | None = None) -> None:
        super().__init__(
            status_code=400,
            error="bad_request",
            message=message,
            reason=reason,
            denied_key=denied_key,
        )


class PayloadTooLargeError(TelemetryApiError):
    """Được raise khi request ingest vượt giới hạn byte đã cấu hình."""

    def __init__(self) -> None:
        super().__init__(
            status_code=413,
            error="payload_too_large",
            message="Request payload exceeds max allowed size",
            reason="payload_too_large",
        )


class InternalTelemetryError(TelemetryApiError):
    """Được raise khi lỗi storage/runtime không được để lộ chi tiết nội bộ."""

    def __init__(self) -> None:
        super().__init__(
            status_code=500,
            error="internal_error",
            message="Telemetry ingest failed",
            reason="internal_error",
        )
