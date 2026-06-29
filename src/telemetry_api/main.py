"""Hàm tạo ứng dụng FastAPI cho CDO Telemetry API."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.responses import JSONResponse

from telemetry_api.adapters.amp_adapter_stub import AmpTelemetryAdapter
from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.adapters.local_jsonl_adapter import LocalJsonlTelemetryAdapter
from telemetry_api.core.config import Settings, load_settings
from telemetry_api.core.errors import InternalTelemetryError, TelemetryApiError
from telemetry_api.core.logging import configure_logging, log_structured, now_utc_iso
from telemetry_api.middleware.correlation_id import CorrelationIdMiddleware, get_or_create_correlation_id
from telemetry_api.middleware.payload_size_limit import PayloadSizeLimitMiddleware
from telemetry_api.observability.metrics import record_ingest_rejected
from telemetry_api.routes.health import router as health_router
from telemetry_api.routes.ingest import router as ingest_router
from telemetry_api.routes.metrics import router as metrics_router
from telemetry_api.services.ingest_service import IngestService
from telemetry_api.observability.prometheus_exporter import PrometheusTelemetryExporter
from prometheus_client import CollectorRegistry


logger = logging.getLogger("telemetry_api.ingest")


def create_app(
    settings: Settings | None = None,
    storage_adapter: TelemetryStorageAdapter | None = None,
) -> FastAPI:
    """Tạo FastAPI app đã cấu hình với dependency có thể inject khi test."""

    resolved_settings = settings or load_settings()
    configure_logging(resolved_settings.log_level)
    adapter = storage_adapter or build_storage_adapter(resolved_settings)

    # Khởi tạo Prometheus registry và exporter cục bộ cho app instance
    registry = CollectorRegistry()
    prometheus_exporter = PrometheusTelemetryExporter(registry=registry)

    app = FastAPI(title=resolved_settings.app_name)
    app.state.settings = resolved_settings
    app.state.prometheus_registry = registry
    app.state.prometheus_exporter = prometheus_exporter
    app.state.ingest_service = IngestService(adapter, prometheus_exporter)

    app.add_middleware(PayloadSizeLimitMiddleware, max_payload_bytes=resolved_settings.max_ingest_payload_bytes)
    app.add_middleware(CorrelationIdMiddleware)

    # Đăng ký các router hoạt động
    app.include_router(health_router)
    app.include_router(ingest_router)
    app.include_router(metrics_router)

    _register_exception_handlers(app)

    return app


def build_storage_adapter(settings: Settings) -> TelemetryStorageAdapter:
    """Khởi tạo telemetry storage adapter theo cấu hình hoặc dừng sớm khi sai."""

    backend = settings.telemetry_storage_backend
    if backend == "local_jsonl":
        return LocalJsonlTelemetryAdapter(settings.local_telemetry_file)
    if backend == "amp":
        return AmpTelemetryAdapter()
    raise ValueError(f"Unknown TELEMETRY_STORAGE_BACKEND: {backend}")


def _register_exception_handlers(app: FastAPI) -> None:
    """Đăng ký exception handler JSON an toàn cho lỗi API."""

    @app.exception_handler(TelemetryApiError)
    async def telemetry_api_error_handler(request: Request, exc: TelemetryApiError) -> JSONResponse:
        """Trả JSON lỗi theo contract và log ingest request bị reject."""

        correlation_id = get_or_create_correlation_id(request)

        # Định tuyến tăng bộ đếm metric theo lý do và phân loại
        from telemetry_api.observability.metrics import (
            record_cardinality_rejection,
            record_ingest_rejected,
            record_metric_rejection,
            record_pii_rejection,
        )

        if exc.reason == "pii_denylist_label":
            record_pii_rejection(exc.reason)
        elif exc.reason in ("high_cardinality_label", "raw_endpoint_path_with_ids"):
            record_cardinality_rejection(exc.reason)
        elif exc.reason in (
            "unsupported_metric_type",
            "internal_only_metric_not_ai_signal",
            "missing_required_label",
            "empty_required_label",
        ):
            record_metric_rejection(exc.reason)
        else:
            record_ingest_rejected(exc.reason)

        _log_rejected_request(
            request,
            exc.status_code,
            exc.message,
            correlation_id,
            exc.reason,
            denied_key=exc.denied_key,
            missing_label=exc.missing_label,
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "error": exc.error,
                "message": exc.message,
                "correlation_id": correlation_id,
            },
        )

    @app.exception_handler(RequestValidationError)
    async def request_validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
        """Chuyển validation response mặc định 422 của FastAPI thành 400 theo task."""

        correlation_id = get_or_create_correlation_id(request)
        message = "Invalid request"
        # Xác định lý do từ chối từ lỗi validation của FastAPI (thường là lỗi kiểu dữ liệu URL/Query)
        first_err_msg = exc.errors()[0].get("msg", "") if exc.errors() else ""
        reason = "bad_request"
        if "X-Tenant-Id" in first_err_msg or "header" in first_err_msg:
            reason = "missing_tenant_header"

        record_ingest_rejected(reason)
        _log_rejected_request(request, 400, message, correlation_id, reason)
        return JSONResponse(
            status_code=400,
            content={
                "error": "bad_request",
                "message": message,
                "correlation_id": correlation_id,
            },
        )

    @app.exception_handler(Exception)
    async def unhandled_error_handler(request: Request, exc: Exception) -> JSONResponse:
        """Ẩn chi tiết exception ngoài dự kiến khỏi API client."""

        correlation_id = get_or_create_correlation_id(request)
        internal_error = InternalTelemetryError()
        record_ingest_rejected(internal_error.reason)
        context = _request_context(request)
        log_structured(
            logger,
            logging.ERROR,
            "telemetry_ingest_failed",
            correlation_id=correlation_id,
            status_code=500,
            error=str(exc),
            received_at=now_utc_iso(),
            path=request.url.path,
            method=request.method,
            **context,
        )
        return JSONResponse(
            status_code=internal_error.status_code,
            content={
                "error": internal_error.error,
                "message": internal_error.message,
                "correlation_id": correlation_id,
            },
        )


def _log_rejected_request(
    request: Request,
    status_code: int,
    error: str,
    correlation_id: str,
    reason: str,
    denied_key: str | None = None,
    missing_label: str | None = None,
) -> None:
    """Ghi log có cấu trúc cho các lần ingest thất bại."""

    log_fields: dict[str, Any] = {
        "correlation_id": correlation_id,
        "status_code": status_code,
        "reason": reason,
        "received_at": now_utc_iso(),
        "path": request.url.path,
        "method": request.method,
    }
    if denied_key is not None:
        log_fields["denied_key"] = denied_key
    if missing_label is not None:
        log_fields["missing_label"] = missing_label

    log_structured(
        logger,
        logging.WARNING,
        "telemetry_ingest_rejected",
        **log_fields,
        **_request_context(request),
    )


def _request_context(request: Request) -> dict[str, object]:
    """Trả về các định danh telemetry tùy chọn đã được route gắn vào request."""

    context = getattr(request.state, "ingest_context", {}) or {}
    return {
        "tenant_id": context.get("tenant_id"),
        "service_id": context.get("service_id"),
        "metric_type": context.get("metric_type"),
    }


app = create_app()
