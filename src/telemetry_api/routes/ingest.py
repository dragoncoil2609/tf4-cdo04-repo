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
from telemetry_api.core.logging import log_structured
from telemetry_api.middleware.correlation_id import get_or_create_correlation_id
from telemetry_api.observability.metrics import record_ingest_accepted
from telemetry_api.schemas.telemetry import REQUIRED_TELEMETRY_FIELDS, TelemetryPayload


router = APIRouter()
logger = logging.getLogger("telemetry_api.ingest")


@router.post("/v1/ingest")
async def ingest_telemetry(request: Request) -> JSONResponse:
    """Kiểm tra hợp lệ và lưu một datapoint telemetry từ producer service."""

    correlation_id = get_or_create_correlation_id(request)

    # 1. Đọc và kiểm tra Header X-Tenant-Id
    tenant_id_header = request.headers.get("X-Tenant-Id")
    if tenant_id_header is None:
        raise BadRequestError("X-Tenant-Id header is required", reason="missing_tenant_header")
    header_tenant_id = tenant_id_header.strip()
    if not header_tenant_id:
        raise BadRequestError("X-Tenant-Id header is required", reason="missing_tenant_header")

    # 2. Đọc và parse JSON body
    try:
        payload_data = await _parse_json_body(request)
    except BadRequestError as exc:
        raise BadRequestError(exc.message, reason="invalid_json") from exc

    _attach_log_context(request, payload_data)

    # 3. Kiểm tra các trường bắt buộc trước khi validate schema
    for field in REQUIRED_TELEMETRY_FIELDS:
        if field not in payload_data:
            raise BadRequestError(f"Missing required field: {field}", reason="missing_required_field")

    # 4. Kiểm tra hợp lệ kiểu dữ liệu và nghiệp vụ (Pydantic validation)
    try:
        payload = TelemetryPayload.model_validate(payload_data)
    except ValidationError as exc:
        reason = _determine_rejection_reason_from_exc(exc)
        raise BadRequestError(_validation_message(exc), reason=reason) from exc

    # 5. So khớp chéo Tenant ID header và body
    if header_tenant_id != payload.tenant_id:
        raise BadRequestError("X-Tenant-Id does not match body tenant_id", reason="tenant_mismatch")

    # 6. Gọi service thực hiện lưu telemetry
    request.state.ingest_context = _context_from_payload(payload.model_dump())
    service = get_ingest_service(request)
    record = service.ingest(payload, header_tenant_id, correlation_id)

    # 7. Ghi nhận metrics thành công và log sự kiện
    record_ingest_accepted()
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


def _determine_rejection_reason_from_exc(error: ValidationError) -> str:
    """Xác định lý do từ chối cụ thể dựa trên lỗi kiểm thử Pydantic."""

    first_error = error.errors()[0]
    loc = [str(part) for part in first_error.get("loc", ())]
    msg = first_error.get("msg", "").lower()

    if "ts" in loc:
        return "invalid_timestamp"
    if "value" in loc:
        return "invalid_value"
    if "tenant_id" in loc:
        return "empty_tenant_id"
    if "service_id" in loc:
        return "empty_service_id"
    if "metric_type" in loc:
        if "unsupported" in msg:
            return "unsupported_metric_type"
        return "empty_metric_type"
    if "labels" in loc:
        if "nested" in msg:
            return "nested_label_object"
        if "must be string, number, boolean or null" in msg:
            return "invalid_label_value_type"
        if "high-cardinality" in msg:
            return "high_cardinality_label"
        if "sensitive" in msg:
            return "sensitive_label"
        return "invalid_labels_type"

    return "bad_request"


def _validation_message(error: ValidationError) -> str:
    """Chuyển chi tiết validation của Pydantic thành thông báo ngắn cho client."""

    first_error = error.errors()[0]
    message = first_error.get("msg", "Invalid telemetry payload")
    if message.startswith("Value error, "):
        message = message[len("Value error, "):]
    return message


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
