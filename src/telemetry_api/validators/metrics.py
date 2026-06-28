"""Bộ xác thực (Validator) chính sách metric cho Telemetry API."""

from __future__ import annotations

from typing import Any

# 7 AI signals được ký hợp đồng cho phép
AI_SIGNAL_ALLOWLIST = {
    "cpu_usage_percent",
    "memory_usage_percent",
    "active_connections",
    "db_connection_pool_pct",
    "queue_depth",
    "cache_hit_rate_pct",
    "api_latency_ms",
}

# Các metric nội bộ, chưa thuộc AI contract nên bị từ chối
INTERNAL_ONLY_METRICS = {
    "error_rate",
    "oldest_message_age_seconds",
}

# Nhãn bắt buộc của từng loại metric
METRIC_REQUIRED_LABELS = {
    "cpu_usage_percent": {"region"},
    "memory_usage_percent": {"region"},
    "active_connections": {"region"},
    "api_latency_ms": {"region"},
    "db_connection_pool_pct": {"region", "db_type"},
    "queue_depth": {"region", "queue_name"},
    "cache_hit_rate_pct": {"region", "cache_type"},
}


def validate_metric_and_labels(metric_type: str, labels: Any) -> None:
    """Xác thực tính hợp lệ của metric_type và các nhãn bắt buộc.

    Args:
        metric_type: Loại metric gửi lên.
        labels: Bộ nhãn đi kèm.

    Raises:
        ValueError: Nếu vi phạm chính sách metric hoặc thiếu/rỗng nhãn bắt buộc.
    """

    # 1. Kiểm tra xem metric_type có thuộc nhóm chỉ dùng nội bộ (Internal-only) hay không
    if metric_type in INTERNAL_ONLY_METRICS:
        # These metrics may be used later for dashboards/fallback, but they are not part of the signed AI telemetry contract and must not be included in AI signal_window.
        raise ValueError(
            f"metric_type is internal-only and must not be sent as AI signal: {metric_type}"
        )

    # 2. Kiểm tra xem metric_type có thuộc AI_SIGNAL_ALLOWLIST hay không
    if metric_type not in AI_SIGNAL_ALLOWLIST:
        raise ValueError(
            f"metric_type is not in AI signal allowlist: {metric_type}"
        )

    # 3. Xác thực các nhãn bắt buộc (Required Labels)
    required_labels = METRIC_REQUIRED_LABELS.get(metric_type, set())

    if not isinstance(labels, dict):
        if required_labels:
            missing = sorted(list(required_labels))[0]
            raise ValueError(f"metric_type {metric_type} requires label: {missing}")
        return

    # Quét kiểm tra từng nhãn bắt buộc
    for req_label in sorted(list(required_labels)):
        if req_label not in labels:
            raise ValueError(f"metric_type {metric_type} requires label: {req_label}")

        val = labels[req_label]
        # Giá trị nhãn bắt buộc không được None hoặc chuỗi rỗng/chỉ chứa khoảng trắng
        if val is None or (isinstance(val, str) and not val.strip()):
            raise ValueError(f"required label '{req_label}' cannot be empty")
