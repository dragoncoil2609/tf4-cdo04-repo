"""Quy tắc validation để label telemetry an toàn."""

from __future__ import annotations

from typing import Any


HIGH_CARDINALITY_LABEL_KEYS = frozenset(
    {
        "request_id",
        "trace_id",
        "session_id",
        "user_id",
        "raw_path",
        "path_with_id",
        "prediction_id",
    }
)

SENSITIVE_LABEL_MARKERS = (
    "password",
    "token",
    "secret",
    "authorization",
    "api_key",
    "email",
    "phone",
    "credential",
)


def validate_labels(labels: dict[str, Any] | None) -> dict[str, Any]:
    """Từ chối label có nguy cơ lộ dữ liệu nhạy cảm hoặc tăng cardinality."""

    if labels is None:
        return {}

    for key, value in labels.items():
        if not isinstance(key, str) or not key.strip():
            raise ValueError("label keys must be non-empty strings")

        key_normalized = key.strip().lower()
        if key_normalized in HIGH_CARDINALITY_LABEL_KEYS:
            raise ValueError(f"label '{key}' is high-cardinality and not allowed")

        if _contains_sensitive_marker(key_normalized):
            raise ValueError(f"label '{key}' contains sensitive data marker")

        if isinstance(value, str) and _contains_sensitive_marker(value.lower()):
            raise ValueError(f"label '{key}' value contains sensitive data marker")

    return labels


def _contains_sensitive_marker(value: str) -> bool:
    """Trả về True khi key/value của label chứa dấu hiệu dữ liệu nhạy cảm."""

    return any(marker in value for marker in SENSITIVE_LABEL_MARKERS)
