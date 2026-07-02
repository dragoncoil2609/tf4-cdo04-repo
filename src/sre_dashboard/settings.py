"""Runtime settings for the SRE Dashboard backend.

Loads from environment variables with safe defaults for local development.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Immutable settings for the SRE Dashboard service."""

    # ── App identity ──────────────────────────────────────────────
    app_name: str = "sre-dashboard"
    app_version: str = "0.1.0"
    log_level: str = "INFO"

    # ── Binding ───────────────────────────────────────────────────
    host: str = "127.0.0.1"
    port: int = 8001

    # ── AWS region for SSO / STS / service clients ────────────────
    aws_region: str = "us-east-1"

    # ── Terraform output directory (mounted read-only) ────────────
    terraform_output_dir: str = "/terraform"

    # ── DynamoDB table names ──────────────────────────────────────
    audit_table_name: str = "cdo04-audit-logs"
    policy_table_name: str = "cdo04-service-policies"

    # ── AWS SSO profile name ──────────────────────────────────────
    aws_profile: str | None = None


def _read_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc


def load_settings() -> Settings:
    """Load settings from environment variables."""
    return Settings(
        app_name=os.getenv("APP_NAME", Settings.app_name),
        app_version=os.getenv("APP_VERSION", Settings.app_version),
        log_level=os.getenv("LOG_LEVEL", Settings.log_level),
        host=os.getenv("HOST", Settings.host),
        port=_read_int("PORT", Settings.port),
        aws_region=os.getenv("AWS_REGION", Settings.aws_region),
        terraform_output_dir=os.getenv(
            "TERRAFORM_OUTPUT_DIR", Settings.terraform_output_dir
        ),
        audit_table_name=os.getenv(
            "DYNAMODB_AUDIT_TABLE", Settings.audit_table_name
        ),
        policy_table_name=os.getenv(
            "DYNAMODB_POLICY_TABLE", Settings.policy_table_name
        ),
        aws_profile=os.getenv("AWS_PROFILE") or None,
    )
