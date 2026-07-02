"""Metrics service — templated PromQL queries against Amazon Managed Prometheus (AMP).

No raw PromQL input is accepted from callers. Metric types are validated
against a predefined set. PromQL is constructed server-side from validated
parameters.
"""

from __future__ import annotations

import logging
from typing import Any

from sre_dashboard.services.aws_client import AwsClientFactory

logger = logging.getLogger("sre_dashboard.metrics")

# The seven supported metric types (aligned with prediction_worker/app.py)
VALID_METRIC_TYPES = frozenset({
    "cpu_usage_percent",
    "memory_usage_percent",
    "active_connections",
    "db_connection_pool_pct",
    "queue_depth",
    "cache_hit_rate_pct",
    "api_latency_ms",
})

# Each metric uses a simple PromQL that selects by tenant_id and service_id.
# Dashboard passes the same query range AMP used by the prediction worker.
METRIC_TEMPLATES: dict[str, str] = {
    "cpu_usage_percent":      'cpu_usage_percent{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "memory_usage_percent":   'memory_usage_percent{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "active_connections":     'active_connections{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "db_connection_pool_pct": 'db_connection_pool_pct{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "queue_depth":            'queue_depth{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "cache_hit_rate_pct":     'cache_hit_rate_pct{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
    "api_latency_ms":         'api_latency_ms{{tenant_id="{tenant_id}",service_id="{service_id}"}}',
}


class MetricsService:
    """Builds and executes PromQL queries against AMP endpoint.

    The AMP workspace URL is discovered from Terraform outputs. PromQL is
    built server-side — no raw user input becomes part of the query.
    """

    def __init__(
        self,
        aws_client_factory: AwsClientFactory,
        amp_query_endpoint: str | None = None,
    ) -> None:
        self._aws = aws_client_factory
        self._amp_query_endpoint = amp_query_endpoint

    @staticmethod
    def validate_metric_type(metric_type: str) -> str:
        """Validate and normalize a metric type string.

        Raises ValueError if the metric type is not in the supported set.
        """
        normalized = metric_type.strip().lower()
        if normalized not in VALID_METRIC_TYPES:
            raise ValueError(
                f"Unsupported metric_type '{metric_type}'. "
                f"Must be one of: {', '.join(sorted(VALID_METRIC_TYPES))}"
            )
        return normalized

    @staticmethod
    def build_promql(metric_type: str, tenant_id: str, service_id: str) -> str:
        """Build a PromQL query string from validated parameters.

        No raw user input appears in the output. Metric type must be one of
        the predefined seven.
        """
        normalized = MetricsService.validate_metric_type(metric_type)
        template = METRIC_TEMPLATES[normalized]
        return template.format(tenant_id=tenant_id, service_id=service_id)

    def query_metrics(
        self,
        metric_type: str,
        tenant_id: str,
        service_id: str,
        range_minutes: int = 120,
    ) -> dict[str, Any]:
        """Query AMP for a single metric type.

        Returns the aligned time-series data or an error dict.
        """
        import time as time_module

        if not self._amp_query_endpoint:
            return {"status": "error", "detail": "AMP query endpoint not configured"}

        promql = self.build_promql(metric_type, tenant_id, service_id)
        end_time = int(time_module.time())
        start_time = end_time - (range_minutes * 60)

        import requests
        from requests_aws4auth import AWS4Auth

        session = self._aws._session
        credentials = session.get_credentials()
        if not credentials:
            return {"status": "error", "detail": "No AWS credentials available"}

        frozen = credentials.get_frozen_credentials()
        auth = AWS4Auth(
            frozen.access_key,
            frozen.secret_key,
            self._aws._region,
            "aps",
            session_token=frozen.token,
        )

        base = self._amp_query_endpoint.rstrip("/").removesuffix("/api/v1/query")
        url = f"{base}/api/v1/query_range"

        params = {
            "query": promql,
            "start": start_time,
            "end": end_time,
            "step": "60",
        }

        try:
            response = requests.get(url, auth=auth, params=params, timeout=15)
            if response.status_code != 200:
                return {
                    "status": "error",
                    "detail": f"AMP query failed: HTTP {response.status_code}",
                }
            data = response.json().get("data", {})
            result = data.get("result", [])
            # Flatten into time-value pairs
            series = []
            for s in result:
                series.append({
                    "metric": s.get("metric", {}),
                    "values": [
                        {"timestamp": int(float(ts)), "value": float(val)}
                        for ts, val in s.get("values", [])
                    ],
                })
            return {
                "status": "ok",
                "metric_type": metric_type,
                "tenant_id": tenant_id,
                "service_id": service_id,
                "series": series,
                "query_range": {"start": start_time, "end": end_time, "step": 60},
            }
        except Exception as exc:
            logger.warning("AMP query_range error for %s/%s: %s", tenant_id, service_id, exc)
            return {"status": "error", "detail": str(exc)}
