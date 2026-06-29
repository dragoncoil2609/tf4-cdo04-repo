import uuid
import json
import os
import hashlib
from datetime import datetime, timezone
from typing import Any, Dict

# AUDIT_BACKEND=local (default, dev) writes JSONL to disk; =s3 writes one encrypted
# object per decision (KMS at rest, retention via bucket lifecycle) per ai-api-contract.md.
AUDIT_BACKEND = os.getenv("AUDIT_BACKEND", "local")
AUDIT_S3_BUCKET = os.getenv("AUDIT_S3_BUCKET", "")
AUDIT_S3_PREFIX = os.getenv("AUDIT_S3_PREFIX", "audit/")
AUDIT_KMS_KEY = os.getenv("AUDIT_KMS_KEY_ID", "")


class AuditLogger:
    def __init__(self, log_dir: str = "logs"):
        self.log_dir = log_dir
        if AUDIT_BACKEND == "local" and not os.path.exists(self.log_dir):
            os.makedirs(self.log_dir)

    def log_decision(self, tenant_id: str, request_data: Dict[str, Any], response_data: Dict[str, Any]) -> uuid.UUID:
        audit_id = uuid.uuid4()
        now = datetime.now(timezone.utc)

        # Hash signal_window for traceability without storing raw PII (ai-api-contract.md)
        signal_window_data = request_data.get("signal_window", [])
        input_hash = hashlib.sha256(json.dumps(signal_window_data, default=str).encode()).hexdigest()

        # 6 mandatory fields (ai-api-contract.md Audit Log Schema)
        log_entry = {
            "audit_id": str(audit_id),
            "timestamp": now.isoformat(),
            "tenant_id": tenant_id,
            "principal_id": request_data.get("principal_id", "unknown-principal"),
            "input_hash": f"sha256:{input_hash}",
            "recommendation_snapshot": response_data.get("recommendation", {}),
        }

        if AUDIT_BACKEND == "s3":
            self._write_s3(log_entry, now)
        else:
            self._write_local(log_entry, now)
        return audit_id

    def _write_local(self, entry: Dict[str, Any], now: datetime) -> None:
        path = os.path.join(self.log_dir, f"audit_{now.strftime('%Y%m%d')}.jsonl")
        with open(path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _write_s3(self, entry: Dict[str, Any], now: datetime) -> None:
        import boto3  # lazy: only needed in prod
        key = f"{AUDIT_S3_PREFIX}{now.strftime('%Y/%m/%d')}/{entry['audit_id']}.json"
        extra = {"ServerSideEncryption": "aws:kms"}
        if AUDIT_KMS_KEY:
            extra["SSEKMSKeyId"] = AUDIT_KMS_KEY
        boto3.client("s3").put_object(
            Bucket=AUDIT_S3_BUCKET, Key=key, Body=json.dumps(entry).encode(),
            ContentType="application/json", **extra)
