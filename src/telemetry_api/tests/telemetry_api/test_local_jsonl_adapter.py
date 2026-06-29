"""Kiểm thử đơn vị cho storage adapter telemetry JSONL local."""

from __future__ import annotations

import json
from pathlib import Path

from telemetry_api.adapters.local_jsonl_adapter import LocalJsonlTelemetryAdapter
from telemetry_api.schemas.telemetry import TelemetryRecord


def record(correlation_id: str) -> TelemetryRecord:
    """Tạo telemetry record tối thiểu để kiểm thử adapter."""

    return TelemetryRecord(
        correlation_id=correlation_id,
        received_at="2026-06-25T10:30:01Z",
        ts="2026-06-25T10:30:00Z",
        tenant_id="demo-tenant-001",
        service_id="payment-gateway",
        metric_type="api_latency_ms",
        value=450.5,
        labels={"region": "us-east-1"},
    )


def test_local_adapter_creates_folder_if_missing(tmp_path: Path) -> None:
    """Adapter local tạo thư mục cha trước khi ghi JSONL."""

    file_path = tmp_path / "missing" / "nested" / "telemetry.jsonl"
    adapter = LocalJsonlTelemetryAdapter(file_path)

    adapter.store(record("corr-1"))

    assert file_path.exists()
    stored = json.loads(file_path.read_text(encoding="utf-8").splitlines()[0])
    assert stored["correlation_id"] == "corr-1"


def test_local_adapter_appends_without_overwriting(tmp_path: Path) -> None:
    """Nhiều record được ghi nối tiếp thành các dòng JSON riêng biệt."""

    file_path = tmp_path / "telemetry.jsonl"
    adapter = LocalJsonlTelemetryAdapter(file_path)

    adapter.store(record("corr-1"))
    adapter.store(record("corr-2"))

    lines = file_path.read_text(encoding="utf-8").splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0])["correlation_id"] == "corr-1"
    assert json.loads(lines[1])["correlation_id"] == "corr-2"
