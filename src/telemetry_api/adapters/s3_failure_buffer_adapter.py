"""Adapter ghi nhận telemetry thất bại vào S3 failure buffer."""

from __future__ import annotations

import json
import logging
import os
import boto3
from botocore.exceptions import BotoCoreError, ClientError

from telemetry_api.core.config import Settings
from telemetry_api.core.logging import now_utc_iso
from telemetry_api.schemas.telemetry import TelemetryPayload

logger = logging.getLogger("telemetry_api.s3_buffer")


class S3FailureBufferAdapter:
    """Adapter lưu trữ telemetry failed vào S3 bucket hoặc giả lập local."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._s3_client = None

    def _get_s3_client(self) -> boto3.client:
        if self._s3_client is None:
            self._s3_client = boto3.client("s3", region_name=self.settings.aws_region)
        return self._s3_client

    def write(
        self,
        payload: TelemetryPayload,
        event_id: str,
        correlation_id: str,
        idempotency_key: str,
        retry_count: int,
        failure_reason: str = "amp_delivery_failed_after_retry",
    ) -> str:
        """Ghi payload và metadata vào S3. Trả về object key."""

        if not self.settings.s3_failure_buffer_enabled:
            raise RuntimeError("S3 failure buffer is disabled in settings")

        # 1. Định dạng Object Key
        date_str = payload.ts[:10]  # Trích xuất YYYY-MM-DD
        prefix = self.settings.s3_failure_buffer_prefix or "telemetry-failures/"
        bucket = self.settings.s3_failure_buffer_bucket

        object_key = (
            f"{prefix}tenant_id={payload.tenant_id}/"
            f"service_id={payload.service_id}/"
            f"metric_type={payload.metric_type}/"
            f"date={date_str}/"
            f"idempotency_key={idempotency_key}.json"
        )

        # 2. Xây dựng Object Body JSON
        body_data = {
            "event_id": event_id,
            "request_id": correlation_id,
            "correlation_id": correlation_id,
            "idempotency_key": idempotency_key,
            "failed_at": now_utc_iso(),
            "failure_reason": failure_reason,
            "retry_count": retry_count,
            "source": self.settings.app_name,
            "payload": payload.model_dump(),
        }
        body_str = json.dumps(body_data, indent=2)

        # 3. Metadata headers
        metadata = {
            "idempotency-key": idempotency_key,
            "event-id": event_id,
            "correlation-id": correlation_id,
        }

        # Kiểm tra test flag ép lỗi
        if os.getenv("FORCE_S3_BUFFER_FAIL") == "true":
            logger.warning("Forced S3 buffer failure via FORCE_S3_BUFFER_FAIL env var.")
            raise RuntimeError("S3 failure buffer write failed (forced).")

        # 4. Chế độ giả lập Local (nếu bucket chưa tạo hoặc đang chạy local test)
        if not bucket or (bucket == "cdo-telemetry-failure-buffer" and self.settings.env == "local"):
            local_path = os.path.join("local-store", "s3-mock-buffer", object_key)
            os.makedirs(os.path.dirname(local_path), exist_ok=True)
            with open(local_path, "w", encoding="utf-8") as f:
                f.write(body_str)
            logger.info("Local S3 Buffer Simulation: Written to %s", local_path)
            return object_key

        # 5. Gửi lên AWS S3 thật
        try:
            extra_args = {
                "Metadata": metadata,
                "ContentType": "application/json",
            }
            if self.settings.s3_failure_buffer_kms_key_id:
                extra_args["ServerSideEncryption"] = "aws:kms"
                extra_args["SSEKMSKeyId"] = self.settings.s3_failure_buffer_kms_key_id

            s3 = self._get_s3_client()
            s3.put_object(
                Bucket=bucket,
                Key=object_key,
                Body=body_str,
                **extra_args,
            )
            logger.info("Successfully uploaded failure buffer to s3://%s/%s", bucket, object_key)
            return object_key
        except (BotoCoreError, ClientError) as exc:
            logger.error("Failed to write to S3 failure buffer: %s", exc)
            raise RuntimeError(f"S3 put_object failed: {exc}") from exc
