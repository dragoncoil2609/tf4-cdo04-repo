"""Cơ chế Bounded Retry với Exponential Backoff và Jitter cho Telemetry API."""

from __future__ import annotations

import logging
import random
import time
from typing import Callable

from telemetry_api.adapters.base import DeliveryResult

logger = logging.getLogger("telemetry_api.retry")


def execute_with_retry(
    action: Callable[[], DeliveryResult],
    max_retries: int = 3,
    base_delay_ms: float = 500.0,
    max_delay_ms: float = 5000.0,
    on_retry_callback: Callable[[int, str, str], None] | None = None,
) -> DeliveryResult:
    """Thực hiện một hành động và tự động retry nếu gặp lỗi tạm thời (transient error)."""

    attempt = 0
    while True:
        try:
            result = action()
            if result.success:
                return result

            # Xác định lỗi có phải là tạm thời (transient) hay không
            error_type = result.error_type or "UnknownError"
            is_transient = True

            # Các lỗi client (4xx) ngoại trừ 429 (throttling) được coi là không tạm thời
            if error_type.startswith("HTTP_"):
                try:
                    status_code = int(error_type.split("_")[1])
                    if 400 <= status_code < 500 and status_code != 429:
                        is_transient = False
                except (ValueError, IndexError):
                    pass

            if not is_transient:
                logger.warning("Non-transient error %s detected. Skipping retries.", error_type)
                return result

        except Exception as exc:
            # Gói các ngoại lệ chưa biết thành lỗi Network/Exception
            result = DeliveryResult(
                success=False,
                status="failed",
                error_type="ExceptionRaised",
                error_message=str(exc),
            )
            error_type = "ExceptionRaised"

        attempt += 1
        if attempt > max_retries:
            logger.warning("Max retry attempts (%d) reached. Delivery failed.", max_retries)
            return result

        # Tính toán delay với exponential backoff và jitter
        # Đổi ms sang seconds
        raw_delay_sec = min(max_delay_ms / 1000.0, (base_delay_ms / 1000.0) * (2 ** (attempt - 1)))
        # Jitter ngẫu nhiên từ 50% đến 100% của backoff delay
        delay_sec = raw_delay_sec * (0.5 + random.random() * 0.5)

        if on_retry_callback:
            on_retry_callback(attempt, error_type, result.error_message or "")

        logger.info(
            "AMP delivery attempt %d failed with error %s. Retrying in %.2fs...",
            attempt,
            error_type,
            delay_sec,
        )
        time.sleep(delay_sec)
