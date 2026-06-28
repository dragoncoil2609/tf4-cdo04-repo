"""Hàm tạo ứng dụng FastAPI cho CDO Telemetry API."""

from __future__ import annotations

import logging

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
from telemetry_api.routes.ingest import router as ingest_router
from telemetry_api.services.ingest_service import IngestService


logger = logging.getLogger("telemetry_api.ingest")


def create_app(
    settings: Settings | None = None,
    storage_adapter: TelemetryStorageAdapter | None = None,
) -> FastAPI:
    """Tạo FastAPI app đã cấu hình với dependency có thể inject khi test."""

    resolved_settings = settings or load_settings()
    configure_logging(resolved_settings.log_level)
    adapter = storage_adapter or build_storage_adapter(resolved_settings)

    app = FastAPI(title=resolved_settings.app_name)
    app.state.settings = resolved_settings
    app.state.ingest_service = IngestService(adapter)

    app.add_middleware(PayloadSizeLimitMiddleware, max_payload_bytes=resolved_settings.max_ingest_payload_bytes)
    app.add_middleware(CorrelationIdMiddleware)
    app.include_router(ingest_router)
    _register_exception_handlers(app)

    @app.get("/health")
    async def health() -> dict[str, str]:
        """Trả về health cơ bản của service và storage backend đang dùng."""

        return {
            "status": "ok",
            "service": resolved_settings.app_name,
            "storage_backend": resolved_settings.telemetry_storage_backend,
        }

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
        _log_rejected_request(request, exc.status_code, exc.message, correlation_id)
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
        _log_rejected_request(request, 400, message, correlation_id)
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


def _log_rejected_request(request: Request, status_code: int, error: str, correlation_id: str) -> None:
    """Ghi log có cấu trúc cho các lần ingest thất bại."""

    log_structured(
        logger,
        logging.WARNING,
        "telemetry_ingest_rejected",
        correlation_id=correlation_id,
        status_code=status_code,
        error=error,
        received_at=now_utc_iso(),
        path=request.url.path,
        method=request.method,
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
