"""Metrics routes — time-series data from AMP.

No raw PromQL input is accepted. Metric types are validated against a
predefined set of seven types. PromQL is constructed server-side.

GET /api/metrics/{service_id}?tenant_id=...&range_minutes=120
    — return all 7 metric types for a service.

GET /api/metrics/{service_id}/{metric_type}?tenant_id=...&range_minutes=120
    — return a single metric type for a service.
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request, HTTPException

router = APIRouter()

VALID_METRIC_TYPES = frozenset({
    "cpu_usage_percent",
    "memory_usage_percent",
    "active_connections",
    "db_connection_pool_pct",
    "queue_depth",
    "cache_hit_rate_pct",
    "api_latency_ms",
})


@router.get("/api/metrics/{service_id}")
async def get_all_metrics(
    request: Request,
    service_id: str,
    tenant_id: str = Query(..., description="Tenant ID"),
    range_minutes: int = Query(120, description="Lookback window in minutes"),
):
    """Return all 7 metric types for a service."""
    metrics_service = request.app.state.metrics_service

    results = {}
    for metric_type in sorted(VALID_METRIC_TYPES):
        results[metric_type] = metrics_service.query_metrics(
            metric_type=metric_type,
            tenant_id=tenant_id,
            service_id=service_id,
            range_minutes=range_minutes,
        )

    # If AMP is not configured, return error status
    if not metrics_service._amp_query_endpoint:
        return {
            "status": "error",
            "detail": "AMP query endpoint not configured. Set AMP_QUERY_ENDPOINT or run terraform discovery.",
            "tenant_id": tenant_id,
            "service_id": service_id,
            "metrics": results,
        }

    return {
        "status": "ok",
        "tenant_id": tenant_id,
        "service_id": service_id,
        "range_minutes": range_minutes,
        "metrics": results,
    }


@router.get("/api/metrics/{service_id}/{metric_type}")
async def get_single_metric(
    request: Request,
    service_id: str,
    metric_type: str,
    tenant_id: str = Query(..., description="Tenant ID"),
    range_minutes: int = Query(120, description="Lookback window in minutes"),
):
    """Return a single metric type for a service.

    Validates metric_type against the predefined set.
    """
    metrics_service = request.app.state.metrics_service

    normalized = metric_type.strip().lower()
    if normalized not in VALID_METRIC_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported metric_type '{metric_type}'. "
                   f"Must be one of: {', '.join(sorted(VALID_METRIC_TYPES))}",
        )

    result = metrics_service.query_metrics(
        metric_type=normalized,
        tenant_id=tenant_id,
        service_id=service_id,
        range_minutes=range_minutes,
    )

    return {
        "status": "ok",
        "tenant_id": tenant_id,
        "service_id": service_id,
        "metric_type": normalized,
        "range_minutes": range_minutes,
        "data": result,
    }
