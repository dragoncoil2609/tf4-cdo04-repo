"""Schema cho telemetry request và record lưu trữ."""

from __future__ import annotations

import math
import re
from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, field_validator, model_validator

from telemetry_api.validators.labels import validate_labels


REQUIRED_TELEMETRY_FIELDS = ("ts", "tenant_id", "service_id", "metric_type", "value")

# Chấp nhận định dạng timestamp RFC3339 UTC kết thúc bằng Z/z hoặc múi giờ lệch 0 (ví dụ +00:00, -0000)
_RFC3339_UTC_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})$"
)


class TelemetryPayload(BaseModel):
    """Request body đã được kiểm tra hợp lệ cho POST /v1/ingest."""

    model_config = ConfigDict(extra="forbid")

    ts: str
    tenant_id: str
    service_id: str
    metric_type: str
    value: int | float
    labels: dict[str, Any] | None = None

    @field_validator("ts", mode="before")
    @classmethod
    def validate_ts_type(cls, value: Any) -> Any:
        """Đảm bảo ts truyền lên bắt buộc phải là kiểu chuỗi."""

        if not isinstance(value, str):
            raise ValueError("ts must be a string")
        return value

    @field_validator("ts")
    @classmethod
    def validate_ts(cls, value: str) -> str:
        """Đảm bảo timestamp tuân thủ định dạng RFC3339 UTC."""

        if not _RFC3339_UTC_RE.match(value):
            raise ValueError("ts must be RFC3339 UTC")

        try:
            normalized_value = value
            # Chuẩn hóa Z thành +00:00 để tương thích ngược với Python datetime parsing
            if normalized_value.endswith("Z") or normalized_value.endswith("z"):
                normalized_value = normalized_value[:-1] + "+00:00"
            dt = datetime.fromisoformat(normalized_value)
        except ValueError as exc:
            raise ValueError("ts must be a valid RFC3339 UTC timestamp") from exc

        if dt.tzinfo is None:
            raise ValueError("ts must include timezone")

        if dt.utcoffset().total_seconds() != 0:
            raise ValueError("ts must be in UTC timezone")

        return value

    @field_validator("tenant_id", "service_id", "metric_type", mode="before")
    @classmethod
    def validate_string_types(cls, value: Any) -> Any:
        """Đảm bảo các trường chuỗi bắt buộc không bị ép kiểu ngầm định."""

        if not isinstance(value, str):
            raise ValueError("field must be a string")
        return value

    @field_validator("tenant_id", "service_id", "metric_type")
    @classmethod
    def validate_non_empty_string(cls, value: str) -> str:
        """Đảm bảo các trường chuỗi không được trống hoặc chỉ chứa khoảng trắng."""

        if not value.strip():
            raise ValueError("field must be a non-empty string")
        return value

    @field_validator("metric_type")
    @classmethod
    def validate_metric_type(cls, value: str) -> str:
        """Đảm bảo metric_type được giữ nguyên để model validator kiểm tra chi tiết."""
        return value

    @field_validator("value", mode="before")
    @classmethod
    def validate_numeric_value(cls, value: Any) -> Any:
        """Đảm bảo value là JSON number, không chấp nhận boolean hay kiểu chuỗi."""

        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("value must be a number")

        if math.isnan(value) or math.isinf(value):
            raise ValueError("value must be a finite number")

        return value

    @field_validator("labels", mode="before")
    @classmethod
    def validate_safe_labels(cls, value: Any) -> dict[str, Any] | None:
        """Đảm bảo labels là một JSON object phẳng an toàn."""

        if value is None:
            return {}
        return validate_labels(value)

    @model_validator(mode="after")
    def validate_metrics_and_labels(self) -> TelemetryPayload:
        """Xác thực chính sách metric và các nhãn bắt buộc."""
        from telemetry_api.validators.metrics import validate_metric_and_labels
        validate_metric_and_labels(self.metric_type, self.labels)
        return self


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
