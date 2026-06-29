"""Per-service baseline loader.

Baselines are produced offline by scripts/train_baseline.py (STL seasonal profile +
residual sigma) and committed as evidence. At runtime the engine loads them from a
local file by default; set BASELINE_BACKEND=s3 to fetch from S3 (deployment-contract).
"""
import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Optional

BASELINE_DIR = Path(os.getenv("BASELINE_DIR", Path(__file__).resolve().parents[1] / "baselines"))
BACKEND = os.getenv("BASELINE_BACKEND", "local")  # local | s3
S3_BUCKET = os.getenv("BASELINE_S3_BUCKET", "")
S3_PREFIX = os.getenv("BASELINE_S3_PREFIX", "baselines/")


@lru_cache(maxsize=64)
def load_baseline(service_id: str) -> Optional[dict]:
    """Return the baseline dict for a service, or None if not registered.

    Cached in-memory (5-min TTL semantics handled by container lifecycle / restart).
    """
    if BACKEND == "s3":
        try:
            import boto3  # imported lazily; not needed for local dev
            body = boto3.client("s3").get_object(
                Bucket=S3_BUCKET, Key=f"{S3_PREFIX}{service_id}.json")["Body"].read()
            return json.loads(body)
        except Exception:
            return None
    path = BASELINE_DIR / f"{service_id}.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())
