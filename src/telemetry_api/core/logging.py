"""Tiện ích ghi log JSON có cấu trúc cho event request của Telemetry API."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any


def configure_logging(log_level: str) -> None:
    """Cấu hình logging chuẩn để ghi JSON payload dưới dạng message thuần."""

    logging.basicConfig(level=getattr(logging, log_level.upper(), logging.INFO), format="%(message)s")


def now_utc_iso() -> str:
    """Trả về timestamp UTC hiện tại theo định dạng RFC3339 Zulu."""

    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def log_structured(
    logger: logging.Logger,
    level: int,
    event: str,
    **fields: Any,
) -> None:
    """Ghi một log event JSON có cấu trúc với field event ổn định."""

    payload: dict[str, Any] = {
        "level": logging.getLevelName(level),
        "event": event,
        **fields,
    }
    logger.log(level, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
