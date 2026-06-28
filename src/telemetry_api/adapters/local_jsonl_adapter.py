"""Storage adapter JSONL local cho luồng ingest telemetry local-first."""

from __future__ import annotations

import json
from pathlib import Path

from telemetry_api.adapters.base import TelemetryStorageAdapter
from telemetry_api.schemas.telemetry import TelemetryRecord


class LocalJsonlTelemetryAdapter(TelemetryStorageAdapter):
    """Ghi nối tiếp telemetry record đã chấp nhận vào file JSONL UTF-8."""

    def __init__(self, file_path: str | Path) -> None:
        self.file_path = Path(file_path)

    def store(self, record: TelemetryRecord) -> None:
        """Ghi nối tiếp một telemetry record mà không ghi đè record cũ."""

        self.file_path.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps(
            record.model_dump(),
            ensure_ascii=False,
            separators=(",", ":"),
        )
        with self.file_path.open("a", encoding="utf-8") as handle:
            handle.write(f"{line}\n")
