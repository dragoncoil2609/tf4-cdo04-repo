"""Adapter gửi telemetry trực tiếp tới Amazon Managed Service for Prometheus (AMP)."""

from __future__ import annotations

import logging
import os
import httpx

from telemetry_api.adapters.base import DeliveryResult, TelemetryDeliveryAdapter
from telemetry_api.core.config import Settings
from telemetry_api.schemas.telemetry import TelemetryPayload

logger = logging.getLogger("telemetry_api.amp_delivery")


class AmpDeliveryAdapter(TelemetryDeliveryAdapter):
    """Adapter thực hiện gửi dữ liệu đồng bộ tới AMP hoặc giả lập cho local testing."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def deliver(self, payload: TelemetryPayload, event_id: str, idempotency_key: str) -> DeliveryResult:
        """Gửi telemetry tới AMP endpoint hoặc giả lập thành công/thất bại."""

        # 1. Cho phép ép buộc lỗi để chạy thử nghiệm tích hợp (integration tests)
        if os.getenv("FORCE_AMP_DELIVERY_FAIL") == "true":
            logger.warning("Forced AMP delivery failure via FORCE_AMP_DELIVERY_FAIL env var.")
            return DeliveryResult(
                success=False,
                status="failed",
                error_type="ForcedFailure",
                error_message="AMP delivery failed due to FORCE_AMP_DELIVERY_FAIL setting.",
            )

        endpoint = self.settings.amp_remote_write_endpoint

        # 2. Ở môi trường local hoặc khi không có endpoint thật, ta chạy giả lập thành công (stub mode)
        # Điều này cho phép giữ nguyên luồng scrape bất đồng bộ của ADOT ở môi trường thật
        if not endpoint or self.settings.env == "local":
            logger.info("AMP delivery stub: simulation success (no remote write endpoint or local env).")
            return DeliveryResult(success=True, status="delivered")

        # 3. Gửi request HTTP POST thật đến endpoint AMP (kiểm tra kết nối)
        try:
            headers = {
                "Content-Type": "application/json",
                "X-Idempotency-Key": idempotency_key,
                "X-Event-Id": event_id,
            }
            # Sử dụng httpx để thực hiện cuộc gọi
            with httpx.Client(timeout=3.0) as client:
                response = client.post(
                    endpoint,
                    json=payload.model_dump(),
                    headers=headers,
                )
                if response.status_code in (200, 201, 202, 204):
                    logger.info("AMP delivery success: HTTP %d", response.status_code)
                    return DeliveryResult(success=True, status="delivered")
                else:
                    logger.error(
                        "AMP delivery failed with status %d: %s",
                        response.status_code,
                        response.text,
                    )
                    return DeliveryResult(
                        success=False,
                        status="failed",
                        error_type=f"HTTP_{response.status_code}",
                        error_message=f"AMP returned HTTP {response.status_code}",
                    )
        except httpx.RequestError as exc:
            logger.error("AMP delivery request error: %s", exc)
            return DeliveryResult(
                success=False,
                status="failed",
                error_type="NetworkError",
                error_message=str(exc),
            )
