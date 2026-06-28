"""Middleware correlation ID để trace request."""

from __future__ import annotations

from uuid import uuid4

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response


CORRELATION_ID_HEADER = "X-Correlation-Id"


def get_or_create_correlation_id(request: Request) -> str:
    """Trả về correlation ID của request, chỉ tự sinh khi thiếu."""

    existing = getattr(request.state, "correlation_id", None)
    if existing:
        return existing

    header_value = request.headers.get(CORRELATION_ID_HEADER)
    correlation_id = header_value.strip() if header_value and header_value.strip() else str(uuid4())
    request.state.correlation_id = correlation_id
    return correlation_id


class CorrelationIdMiddleware(BaseHTTPMiddleware):
    """Gắn một correlation ID duy nhất vào request và response."""

    async def dispatch(self, request: Request, call_next) -> Response:
        """Gán request.state.correlation_id trước khi route xử lý."""

        correlation_id = get_or_create_correlation_id(request)
        response = await call_next(request)
        response.headers[CORRELATION_ID_HEADER] = correlation_id
        return response
