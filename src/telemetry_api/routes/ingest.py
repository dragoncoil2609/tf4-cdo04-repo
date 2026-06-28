"""Route POST /v1/ingest cho luồng nhận telemetry local-first."""

from __future__ import annotations

import json
import logging
from json import JSONDecodeError
from typing import Any

from fastapi import APIRouter, Request
from pydantic import ValidationError
from starlette.responses import JSONResponse

from telemetry_api.core.app_state import get_ingest_service
from telemetry_api.core.errors import BadRequestError
from telemetry_api.core.logging import log_structured, now_utc_iso
from telemetry_api.middleware.correlation_id import get_or_create_correlation_id
from telemetry_api.schemas.telemetry import REQUIRED_TELEMETRY_FIELDS, TelemetryPayload


router = APIRouter()
logger = logging.getLogger("telemetry_api.ingest")


@router.post("/v1/ingest")
async def ingest_telemetry(request: Request) -> JSONResponse:
    """Kiểm tra hợp lệ và lưu một datapoint telemetry từ producer service."""

    correlation_id = get_or_create_correlation_id(request)
    header_tenant_id = _required_tenant_header(request)
    payload_data = await _parse_json_body(request)
    _attach_log_context(request, payload_data)
    _ensure_required_fields(payload_data)

    try:
        payload = TelemetryPayload.model_validate(payload_data)
    except ValidationError as exc:
        raise BadRequestError(_validation_message(exc)) from exc

    request.state.ingest_context = _context_from_payload(payload.model_dump())
    service = get_ingest_service(request)
    record = service.ingest(payload, header_tenant_id, correlation_id)

    log_structured(
        logger,
        logging.INFO,
        "telemetry_ingest_accepted",
        correlation_id=correlation_id,
        tenant_id=record.tenant_id,
        service_id=record.service_id,
        metric_type=record.metric_type,
        status_code=201,
        received_at=record.received_at,
        path=request.url.path,
        method=request.method,
    )
    return JSONResponse(
        status_code=201,
        content={
            "status": "accepted",
            "correlation_id": correlation_id,
            "tenant_id": record.tenant_id,
            "service_id": record.service_id,
            "metric_type": record.metric_type,
        },
    )


def _required_tenant_header(request: Request) -> str:
    """Đọc và validate header X-Tenant-Id bắt buộc."""

    tenant_id = request.headers.get("X-Tenant-Id")
    if tenant_id is None or not tenant_id.strip():
        raise BadRequestError("X-Tenant-Id header is required")
    return tenant_id.strip()


async def _parse_json_body(request: Request) -> dict[str, Any]:
    """Parse JSON request và trả về body dạng dict."""

    raw_body = await request.body()
    try:
        parsed = json.loads(raw_body)
    except (JSONDecodeError, UnicodeDecodeError) as exc:
        raise BadRequestError("Invalid JSON body") from exc

    if not isinstance(parsed, dict):
        raise BadRequestError("Request body must be a JSON object")
    return parsed


def _ensure_required_fields(payload_data: dict[str, Any]) -> None:
    """Trả 400 với message rõ ràng khi thiếu field bắt buộc."""

    for field in REQUIRED_TELEMETRY_FIELDS:
        if field not in payload_data:
            raise BadRequestError(f"Missing required field: {field}")


def _validation_message(error: ValidationError) -> str:
    """Chuyển chi tiết validation của Pydantic thành thông báo ngắn cho client."""

    first_error = error.errors()[0]
    location = ".".join(str(part) for part in first_error.get("loc", []))
    message = first_error.get("msg", "Invalid telemetry payload")
    return f"{location}: {message}" if location else message


def _attach_log_context(request: Request, payload_data: dict[str, Any]) -> None:
    """Gắn các field request tạm thời để error handler log request bị từ chối."""

    request.state.ingest_context = _context_from_payload(payload_data)


def _context_from_payload(payload_data: dict[str, Any]) -> dict[str, Any]:
    """Trích xuất định danh telemetry tùy chọn cho log request có cấu trúc."""

    return {
        "tenant_id": payload_data.get("tenant_id"),
        "service_id": payload_data.get("service_id"),
        "metric_type": payload_data.get("metric_type"),
    }
