"""Tạo Idempotency Key duy nhất và nhất quán cho Telemetry Ingest Payload."""

from __future__ import annotations

import hashlib
import json

from telemetry_api.schemas.telemetry import TelemetryPayload


def generate_idempotency_key(payload: TelemetryPayload) -> str:
    """Tạo khóa idempotency dựa trên các trường thông tin chuẩn hóa của payload."""

    # Sắp xếp các nhãn labels theo thứ tự bảng chữ cái của key
    labels = payload.labels or {}
    sorted_labels = sorted(labels.items())

    # Tạo từ điển canonical ổn định
    canonical_data = {
        "tenant_id": payload.tenant_id,
        "service_id": payload.service_id,
        "metric_type": payload.metric_type,
        "ts": payload.ts,
        "value": float(payload.value) if isinstance(payload.value, (int, float)) else payload.value,
        "labels": sorted_labels,
    }

    # Xuất ra chuỗi JSON chuẩn hóa
    canonical_str = json.dumps(canonical_data, sort_keys=True, separators=(",", ":"))

    # Tính băm SHA-256
    return hashlib.sha256(canonical_str.encode("utf-8")).hexdigest()
