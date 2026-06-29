"""Prometheus Telemetry Exporter for CDO Telemetry Ingest API."""

from __future__ import annotations

import logging
from typing import Any
from prometheus_client import CollectorRegistry, Gauge

from telemetry_api.schemas.telemetry import TelemetryPayload

logger = logging.getLogger("telemetry_api.observability.prometheus_exporter")


class PrometheusTelemetryExporter:
    """Exporter chịu trách nhiệm cập nhật giá trị các Prometheus Gauges."""

    def __init__(self, registry: CollectorRegistry) -> None:
        self.registry = registry
        self._gauges: dict[str, Gauge] = {}

        # Định nghĩa nhãn cụ thể cho từng metric trong 7 AI signals
        self._metric_labels = {
            "cpu_usage_percent": ["tenant_id", "service_id", "region", "env", "service_tier"],
            "memory_usage_percent": ["tenant_id", "service_id", "region", "env", "service_tier"],
            "active_connections": ["tenant_id", "service_id", "region", "env", "service_tier"],
            "api_latency_ms": ["tenant_id", "service_id", "region", "env", "service_tier"],
            "db_connection_pool_pct": ["tenant_id", "service_id", "region", "db_type", "env", "service_tier"],
            "queue_depth": ["tenant_id", "service_id", "region", "queue_name", "env", "service_tier"],
            "cache_hit_rate_pct": ["tenant_id", "service_id", "region", "cache_type", "env", "service_tier"],
        }

        # Đăng ký các Gauges vào registry được cung cấp
        for name, labelnames in self._metric_labels.items():
            self._gauges[name] = Gauge(
                name=name,
                documentation=f"Telemetry metric {name}",
                labelnames=labelnames,
                registry=self.registry,
            )

    def observe(self, payload: TelemetryPayload) -> None:
        """Cập nhật giá trị Prometheus Gauge tương ứng từ TelemetryPayload."""

        metric_type = payload.metric_type
        if metric_type not in self._gauges:
            return

        gauge = self._gauges[metric_type]
        labelnames = self._metric_labels[metric_type]

        # Trích xuất nhãn an toàn từ payload
        labels_dict = payload.labels or {}
        label_values: dict[str, str] = {}

        for name in labelnames:
            if name == "tenant_id":
                label_values[name] = payload.tenant_id
            elif name == "service_id":
                label_values[name] = payload.service_id
            else:
                val = labels_dict.get(name)
                # Chỉ lấy nhãn an toàn, không chứa PII/cardinality cao.
                # Do các nhãn trong payload đã được validate ở tầng ngoài nên ở đây
                # chỉ cần gán giá trị chuỗi (hoặc rỗng nếu không được truyền vào).
                label_values[name] = "" if val is None else str(val)

        try:
            gauge.labels(**label_values).set(payload.value)
        except Exception as exc:
            logger.error("Failed to set Prometheus gauge for metric %s: %s", metric_type, exc)
