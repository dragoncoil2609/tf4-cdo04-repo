"""Quy tắc validation để label telemetry an toàn và đơn giản."""

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


def validate_labels(labels: Any) -> dict[str, Any]:
    """Kiểm tra tính hợp lệ và an toàn của labels.

    Chỉ chấp nhận JSON object phẳng (flat dict) với các value thuộc kiểu đơn giản
    (string, number, boolean, null). Từ chối các label có tính bảo mật cao (PII)
    hoặc có tính phân tán cao (High Cardinality).

    Args:
        labels: Dữ liệu nhãn truyền lên từ client.

    Returns:
        Một dict chứa các labels hợp lệ.
    """

    if labels is None:
        return {}

    if not isinstance(labels, dict):
        raise ValueError("labels must be a JSON object")

    for key, value in labels.items():
        if not isinstance(key, str) or not key.strip():
            raise ValueError("label keys must be non-empty strings")

        # 1. Từ chối nested object hoặc array
        if isinstance(value, (dict, list)):
            raise ValueError(f"labels cannot contain nested objects or arrays for key '{key}'")

        # 2. Chỉ cho phép kiểu dữ liệu đơn giản: string, number, boolean, null (None)
        if value is not None:
            if isinstance(value, bool):
                # bool là kiểu boolean hợp lệ
                pass
            elif isinstance(value, (int, float)):
                # number hợp lệ
                pass
            elif isinstance(value, str):
                # string hợp lệ
                pass
            else:
                raise ValueError(f"label '{key}' value must be string, number, boolean or null")

        # 3. Lọc High Cardinality
        key_normalized = key.strip().lower()
        if key_normalized in HIGH_CARDINALITY_LABEL_KEYS:
            raise ValueError(f"label '{key}' is high-cardinality and not allowed")

        # 4. Lọc thông tin nhạy cảm (PII)
        if _contains_sensitive_marker(key_normalized):
            raise ValueError(f"label '{key}' contains sensitive data marker")

        if isinstance(value, str) and _contains_sensitive_marker(value.lower()):
            raise ValueError(f"label '{key}' value contains sensitive data marker")

    return labels


def _contains_sensitive_marker(value: str) -> bool:
    """Trả về True khi key/value của label chứa dấu hiệu dữ liệu nhạy cảm."""

    return any(marker in value for marker in SENSITIVE_LABEL_MARKERS)
