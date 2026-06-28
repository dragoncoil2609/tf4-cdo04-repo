"""Hàm truy cập có type cho dependency được lưu trong FastAPI app state."""

from __future__ import annotations

from fastapi import Request

from telemetry_api.core.config import Settings
from telemetry_api.services.ingest_service import IngestService


def get_settings(request: Request) -> Settings:
    """Trả về Settings đã gắn vào app khi khởi tạo."""

    return request.app.state.settings


def get_ingest_service(request: Request) -> IngestService:
    """Trả về ingest service đã gắn vào app khi khởi tạo."""

    return request.app.state.ingest_service
