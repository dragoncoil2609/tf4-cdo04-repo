"""Schema cho telemetry request và record lưu trữ."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, field_validator

from telemetry_api.validators.labels import validate_labels


ALLOWED_METRIC_TYPES = frozenset(
    {
        "cpu_usage_percent",
        "memory_usage_percent",
        "active_connections",
        "db_connection_pool_pct",
        "queue_depth",
        "cache_hit_rate_pct",
        "api_latency_ms",
    }
)

REQUIRED_TELEMETRY_FIELDS = ("ts", "tenant_id", "service_id", "metric_type", "value")

_RFC3339_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")


class TelemetryPayload(BaseModel):
    """Request body đã được kiểm tra hợp lệ cho POST /v1/ingest."""

    model_config = ConfigDict(extra="forbid")

    ts: str
    tenant_id: str
    service_id: str
    metric_type: str
    value: int | float
    labels: dict[str, Any] | None = None

    @field_validator("ts")
    @classmethod
    def validate_ts(cls, value: str) -> str:
        """Đảm bảo timestamp là chuỗi RFC3339 UTC kết thúc bằng Z."""

        if not isinstance(value, str) or not _RFC3339_UTC_RE.match(value):
            raise ValueError("ts must be an RFC3339 UTC timestamp ending with Z")
        try:
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError("ts must be a valid RFC3339 UTC timestamp") from exc
        return value

    @field_validator("tenant_id", "service_id", "metric_type")
    @classmethod
    def validate_non_empty_string(cls, value: str) -> str:
        """Đảm bảo các field định danh là chuỗi không rỗng."""

        if not isinstance(value, str) or not value.strip():
            raise ValueError("field must be a non-empty string")
        return value

    @field_validator("metric_type")
    @classmethod
    def validate_metric_type(cls, value: str) -> str:
        """Đảm bảo metric_type nằm trong telemetry contract đã freeze."""

        if value not in ALLOWED_METRIC_TYPES:
            raise ValueError("unsupported metric_type")
        return value

    @field_validator("value", mode="before")
    @classmethod
    def validate_numeric_value(cls, value: Any) -> Any:
        """Đảm bảo value là JSON number, không phải bool hoặc string."""

        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("value must be a number")
        return value

    @field_validator("labels")
    @classmethod
    def validate_safe_labels(cls, value: dict[str, Any] | None) -> dict[str, Any]:
        """Đảm bảo labels an toàn cho lưu metric và truy vấn evidence."""

        return validate_labels(value)


class TelemetryRecord(BaseModel):
    """Record được storage adapter lưu sau khi ingest được chấp nhận."""

    correlation_id: str
    received_at: str
    ts: str
    tenant_id: str
    service_id: str
    metric_type: str
    value: int | float
    labels: dict[str, Any]
    ingest_source: str = "local_api"
