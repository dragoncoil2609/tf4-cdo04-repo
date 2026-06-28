"""Bộ chặn giới hạn kích thước payload cho telemetry ingest request."""

from __future__ import annotations

import logging
from typing import Awaitable, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from telemetry_api.core.logging import log_structured, now_utc_iso
from telemetry_api.middleware.correlation_id import CORRELATION_ID_HEADER, get_or_create_correlation_id
from telemetry_api.observability.metrics import record_ingest_rejected


logger = logging.getLogger("telemetry_api.ingest")


class PayloadSizeLimitMiddleware(BaseHTTPMiddleware):
    """Từ chối body /v1/ingest quá lớn trước khi parse JSON."""

    def __init__(self, app, max_payload_bytes: int) -> None:
        super().__init__(app)
        self.max_payload_bytes = max_payload_bytes

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        """Kiểm tra Content-Length/body bytes trước khi route parse JSON."""

        if request.url.path != "/v1/ingest" or request.method.upper() != "POST":
            return await call_next(request)

        correlation_id = get_or_create_correlation_id(request)
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > self.max_payload_bytes:
                    return self._too_large_response(request, correlation_id)
            except ValueError:
                pass

        body = await request.body()
        if len(body) > self.max_payload_bytes:
            return self._too_large_response(request, correlation_id)

        async def receive() -> dict[str, object]:
            return {"type": "http.request", "body": body, "more_body": False}

        request._receive = receive
        return await call_next(request)

    def _too_large_response(self, request: Request, correlation_id: str) -> JSONResponse:
        """Tạo response 413 cùng format với các lỗi API khác và ghi nhận metrics."""

        record_ingest_rejected("payload_too_large")
        log_structured(
            logger,
            logging.WARNING,
            "telemetry_ingest_rejected",
            correlation_id=correlation_id,
            status_code=413,
            reason="payload_too_large",
            received_at=now_utc_iso(),
            path=request.url.path,
            method=request.method,
        )
        return JSONResponse(
            status_code=413,
            content={
                "error": "payload_too_large",
                "message": "Request payload exceeds max allowed size",
                "correlation_id": correlation_id,
            },
            headers={CORRELATION_ID_HEADER: correlation_id},
        )
