"""Cấu hình runtime cho service Telemetry API."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Các giá trị cấu hình được load từ biến môi trường.

    Giá trị mặc định giúp service chạy local được ngay, đồng thời vẫn giữ đúng
    hình dạng triển khai AWS tương lai trong tài liệu kiến trúc CDO.
    """

    app_name: str = "telemetry-api"
    env: str = "local"
    port: int = 8000
    # Kích thước tối đa của JSON body cho POST /v1/ingest.
    max_ingest_payload_bytes: int = 65536
    telemetry_storage_backend: str = "local_jsonl"
    # Đường dẫn JSONL local dùng cho tới khi adapter AMP remote_write được triển khai.
    local_telemetry_file: str = "local-store/telemetry.jsonl"
    log_level: str = "INFO"


def _read_int(name: str, default: int) -> int:
    """Đọc biến môi trường kiểu số nguyên và báo lỗi rõ khi sai định dạng."""

    value = os.getenv(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc


def load_settings() -> Settings:
    """Nạp cấu hình Telemetry API từ biến môi trường của process."""

    return Settings(
        app_name=os.getenv("APP_NAME", Settings.app_name),
        env=os.getenv("ENV", Settings.env),
        port=_read_int("PORT", Settings.port),
        max_ingest_payload_bytes=_read_int(
            "MAX_INGEST_PAYLOAD_BYTES",
            Settings.max_ingest_payload_bytes,
        ),
        telemetry_storage_backend=os.getenv(
            "TELEMETRY_STORAGE_BACKEND",
            Settings.telemetry_storage_backend,
        ),
        local_telemetry_file=os.getenv(
            "LOCAL_TELEMETRY_FILE",
            Settings.local_telemetry_file,
        ),
        log_level=os.getenv("LOG_LEVEL", Settings.log_level),
    )
