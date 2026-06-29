"""Routes cho Prometheus /metrics và debug JSON metrics."""

from __future__ import annotations

from typing import Any
from fastapi import APIRouter, Request, Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

router = APIRouter()


@router.get("/metrics")
def metrics(request: Request) -> Response:
    """Trả về Prometheus text exposition format cho ADOT Collector/Prometheus Agent scrape."""

    registry = request.app.state.prometheus_registry
    return Response(
        content=generate_latest(registry),
        media_type=CONTENT_TYPE_LATEST,
    )


@router.get("/debug/metrics-json")
def debug_metrics_json() -> dict[str, Any]:
    """Trả về ảnh chụp nhanh các số liệu đo lường local/debug dạng JSON."""

    from telemetry_api.observability.metrics import get_metrics_snapshot
    return get_metrics_snapshot()
