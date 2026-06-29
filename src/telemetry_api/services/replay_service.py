"""Service thực hiện quét và replay telemetry bị lỗi từ S3 failure buffer lên AMP."""

from __future__ import annotations

import json
import logging
import os
import boto3
from botocore.exceptions import BotoCoreError, ClientError

from telemetry_api.adapters.amp_delivery_adapter import AmpDeliveryAdapter
from telemetry_api.core.config import Settings
from telemetry_api.schemas.telemetry import TelemetryPayload

logger = logging.getLogger("telemetry_api.replay_service")


class ReplayService:
    """Service chịu trách nhiệm replay lại dữ liệu lỗi đã lưu ở S3."""

    def __init__(
        self,
        settings: Settings,
        amp_delivery_adapter: AmpDeliveryAdapter,
    ) -> None:
        self.settings = settings
        self.amp_delivery_adapter = amp_delivery_adapter
        self._s3_client = None

    def _get_s3_client(self) -> boto3.client:
        if self._s3_client is None:
            self._s3_client = boto3.client("s3", region_name=self.settings.aws_region)
        return self._s3_client

    def replay_failures(self) -> int:
        """Quét và gửi lại toàn bộ file lỗi trong S3 buffer. Trả về số lượng replay thành công."""

        bucket = self.settings.s3_failure_buffer_bucket
        prefix = self.settings.s3_failure_buffer_prefix or "telemetry-failures/"

        # 1. Chế độ giả lập Local
        if not bucket or (bucket == "cdo-telemetry-failure-buffer" and self.settings.env == "local"):
            logger.info("Local Replay Simulation: scanning local mock buffer folder.")
            mock_dir = os.path.join("local-store", "s3-mock-buffer", prefix)
            if not os.path.exists(mock_dir):
                logger.info("No local mock buffer files found.")
                return 0

            replayed_count = 0
            # Duyệt đệ quy tìm các file json
            for root, _, files in os.walk(mock_dir):
                for file in files:
                    if file.endswith(".json"):
                        file_path = os.path.join(root, file)
                        if self._replay_local_file(file_path):
                            replayed_count += 1
            return replayed_count

        # 2. Xử lý AWS S3 thật
        try:
            s3 = self._get_s3_client()
            paginator = s3.get_paginator("list_objects_v2")
            pages = paginator.paginate(Bucket=bucket, Prefix=prefix)

            replayed_count = 0
            for page in pages:
                if "Contents" not in page:
                    continue

                for obj in page["Contents"]:
                    key = obj["Key"]
                    if not key.endswith(".json"):
                        continue

                    # Thực hiện xử lý một file
                    if self._replay_s3_object(bucket, key):
                        replayed_count += 1

            logger.info("Completed replay execution. Total replayed objects: %d", replayed_count)
            return replayed_count

        except (BotoCoreError, ClientError) as exc:
            logger.error("Error during replay S3 scan: %s", exc)
            return 0

    def _replay_local_file(self, file_path: str) -> bool:
        """Đọc và replay một file local mock buffer."""
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            payload_dict = data.get("payload")
            event_id = data.get("event_id")
            idempotency_key = data.get("idempotency_key")

            if not payload_dict or not idempotency_key or not event_id:
                logger.warning("Invalid mock buffer format in %s", file_path)
                return False

            payload = TelemetryPayload.model_validate(payload_dict)
            # Thử gửi lại AMP
            result = self.amp_delivery_adapter.deliver(payload, event_id, idempotency_key)
            if result.success:
                logger.info("Successfully replayed local file %s. Deleting file.", file_path)
                os.remove(file_path)
                return True
            else:
                logger.warning("Failed to replay local file %s: %s", file_path, result.error_message)
                return False
        except Exception as exc:
            logger.error("Error processing local mock file %s: %s", file_path, exc)
            return False

    def _replay_s3_object(self, bucket: str, key: str) -> bool:
        """Đọc, gửi lại và xóa object khỏi S3 nếu thành công."""
        try:
            s3 = self._get_s3_client()
            resp = s3.get_object(Bucket=bucket, Key=key)
            content = resp["Body"].read().decode("utf-8")
            data = json.loads(content)

            payload_dict = data.get("payload")
            event_id = data.get("event_id")
            idempotency_key = data.get("idempotency_key")

            if not payload_dict or not idempotency_key or not event_id:
                logger.warning("S3 Object %s does not contain valid failure metadata.", key)
                return False

            payload = TelemetryPayload.model_validate(payload_dict)
            result = self.amp_delivery_adapter.deliver(payload, event_id, idempotency_key)

            if result.success:
                logger.info("Replay success for s3://%s/%s. Deleting object.", bucket, key)
                s3.delete_object(Bucket=bucket, Key=key)
                return True
            else:
                logger.warning("Replay failed for s3://%s/%s: %s", bucket, key, result.error_message)
                return False

        except (BotoCoreError, ClientError, Exception) as exc:
            logger.error("Failed to process replay for object s3://%s/%s: %s", bucket, key, exc)
            return False
