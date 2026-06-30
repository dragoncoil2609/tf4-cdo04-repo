"""
test_signal_window.py — CPOA-76 | CDO-W12-034
Kiểm chứng check_signal_window phát hiện đúng window thiếu/đủ.
"""
import pytest
import fallback_engine as fe


def test_full_window_passes(full_window_metrics):
    ok, reason = fe.check_signal_window(full_window_metrics, max_gap_ratio=0.0, policy=None)
    assert ok is True
    assert reason is None


def test_empty_metrics_fails():
    ok, reason = fe.check_signal_window({}, max_gap_ratio=0.0, policy=None)
    assert ok is False
    assert "no metrics" in reason


def test_short_window_fails():
    """Chỉ 60 bucket thay vì 120 → insufficient_signal_window"""
    short_metrics = {"api_latency_ms": {1700000000 + i * 60: 45.0 for i in range(60)}}
    ok, reason = fe.check_signal_window(short_metrics, max_gap_ratio=0.0, policy=None)
    assert ok is False
    assert "60/120" in reason
    assert "insufficient_signal_window" in reason


def test_gap_within_default_limit_passes(full_window_metrics):
    """Default max_missing_buckets=12/120 = 10% gap → 5% gap vẫn pass"""
    ok, reason = fe.check_signal_window(full_window_metrics, max_gap_ratio=0.05, policy=None)
    assert ok is True


def test_gap_exceeds_default_limit_fails(full_window_metrics):
    """Gap 60% vượt xa giới hạn 10% default → fail"""
    ok, reason = fe.check_signal_window(full_window_metrics, max_gap_ratio=0.6, policy=None)
    assert ok is False
    assert "gap_ratio" in reason


def test_gap_within_custom_policy_limit_passes(full_window_metrics):
    """Policy custom cho phép max_missing_buckets=60 (50%) → gap 40% vẫn pass"""
    policy = {"max_missing_buckets": 60}
    ok, reason = fe.check_signal_window(full_window_metrics, max_gap_ratio=0.4, policy=policy)
    assert ok is True


def test_exactly_at_limit_boundary(full_window_metrics):
    """Gap đúng bằng limit (10%) → vẫn pass vì dùng > không phải >="""
    ok, reason = fe.check_signal_window(full_window_metrics, max_gap_ratio=0.10, policy=None)
    assert ok is True


@pytest.mark.parametrize("bucket_count", [0, 1, 50, 100, 119])
def test_various_short_windows_all_fail(bucket_count):
    metrics = {"api_latency_ms": {1700000000 + i * 60: 45.0 for i in range(bucket_count)}}
    ok, _ = fe.check_signal_window(metrics, max_gap_ratio=0.0, policy=None)
    assert ok is False


def test_120_exact_buckets_passes():
    metrics = {"api_latency_ms": {1700000000 + i * 60: 45.0 for i in range(120)}}
    ok, _ = fe.check_signal_window(metrics, max_gap_ratio=0.0, policy=None)
    assert ok is True