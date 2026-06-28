"""Module đo lường và theo dõi (metrics) cho Telemetry Ingest API.

Ghi nhận các số liệu thống kê về số lượng request thành công và thất bại
theo các lý do cụ thể phục vụ cho kiểm thử và tích hợp CloudWatch sau này.
"""

from __future__ import annotations

from typing import Any

# Bộ đếm trong bộ nhớ (In-process counters) cho local metrics
# These local counters are intentionally CloudWatch-ready. In AWS deployment,
# the same rejection events can be exported as CloudWatch custom metrics.
_accepted_total: int = 0
_rejected_total: int = 0
_pii_rejected_total: int = 0
_cardinality_rejected_total: int = 0
_unsupported_metric_rejected_total: int = 0
_internal_only_metric_rejected_total: int = 0
_metric_label_rejected_total: int = 0
_rejected_by_reason: dict[str, int] = {}


def record_ingest_accepted() -> None:
    """Tăng số lượng telemetry ingest thành công lên 1."""

    global _accepted_total
    _accepted_total += 1


def record_ingest_rejected(reason: str) -> None:
    """Tăng số lượng telemetry ingest thất bại lên 1 theo lý do cụ thể.

    Args:
        reason: Mã lý do từ chối (ví dụ: 'invalid_timestamp', 'payload_too_large').
    """

    global _rejected_total
    _rejected_total += 1
    _rejected_by_reason[reason] = _rejected_by_reason.get(reason, 0) + 1


def record_pii_rejection(reason: str) -> None:
    """Tăng bộ đếm từ chối do vi phạm PII và ghi nhận lý do cụ thể."""

    global _pii_rejected_total
    _pii_rejected_total += 1
    record_ingest_rejected(reason)


def record_cardinality_rejection(reason: str) -> None:
    """Tăng bộ đếm từ chối do vi phạm Cardinality và ghi nhận lý do cụ thể."""

    global _cardinality_rejected_total
    _cardinality_rejected_total += 1
    record_ingest_rejected(reason)


def record_metric_rejection(reason: str) -> None:
    """Tăng các bộ đếm từ chối liên quan đến chính sách metric hoặc nhãn bắt buộc."""

    global _unsupported_metric_rejected_total, _internal_only_metric_rejected_total, _metric_label_rejected_total

    if reason == "unsupported_metric_type":
        _unsupported_metric_rejected_total += 1
    elif reason == "internal_only_metric_not_ai_signal":
        _internal_only_metric_rejected_total += 1
    elif reason in ("missing_required_label", "empty_required_label"):
        _metric_label_rejected_total += 1

    record_ingest_rejected(reason)


def get_metrics_snapshot() -> dict[str, Any]:
    """Trả về ảnh chụp nhanh trạng thái metrics hiện tại dưới dạng JSON.

    Returns:
        Một dict chứa các bộ đếm thống kê.
    """

    return {
        "telemetry_ingest_accepted_total": _accepted_total,
        "telemetry_ingest_rejected_total": _rejected_total,
        "telemetry_ingest_pii_rejected_total": _pii_rejected_total,
        "telemetry_ingest_cardinality_rejected_total": _cardinality_rejected_total,
        "telemetry_ingest_unsupported_metric_rejected_total": _unsupported_metric_rejected_total,
        "telemetry_ingest_internal_only_metric_rejected_total": _internal_only_metric_rejected_total,
        "telemetry_ingest_metric_label_rejected_total": _metric_label_rejected_total,
        "telemetry_ingest_rejected_by_reason": dict(_rejected_by_reason),
    }


def reset_metrics_for_tests() -> None:
    """Khởi động lại các bộ đếm về 0, sử dụng cho dọn dẹp sau mỗi unit test."""

    global _accepted_total, _rejected_total, _pii_rejected_total, _cardinality_rejected_total
    global _unsupported_metric_rejected_total, _internal_only_metric_rejected_total, _metric_label_rejected_total
    global _rejected_by_reason

    _accepted_total = 0
    _rejected_total = 0
    _pii_rejected_total = 0
    _cardinality_rejected_total = 0
    _unsupported_metric_rejected_total = 0
    _internal_only_metric_rejected_total = 0
    _metric_label_rejected_total = 0
    _rejected_by_reason = {}
