"""Cấu hình runtime cho service Telemetry API."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Các giá trị cấu hình được load từ biến môi trường.

    Giá trị mặc định giúp service chạy local được ngay, đồng thời vẫn giữ đúng
    hình dạng triển khai AWS tương lai trong tài liệu kiến trúc CDO.
    """

    app_mode: str = "local"
    app_name: str = "telemetry-api"
    app_version: str = "0.1.0"
    build_id: str = "local"
    git_commit_sha: str = "unknown"
    env: str = "local"
    port: int = 8000
    # Kích thước tối đa của JSON body cho POST /v1/ingest.
    max_ingest_payload_bytes: int = 65536
    telemetry_storage_backend: str = "local_jsonl"
    # Đường dẫn JSONL local dùng cho tới khi adapter AMP remote_write được triển khai.
    local_telemetry_file: str = "local-store/telemetry.jsonl"
    log_level: str = "INFO"

    # CDO-W12-019 Configs
    app_metrics_enabled: bool = True
    prometheus_metrics_path: str = "/metrics"
    aws_region: str = "us-east-1"
    amp_workspace_id: str | None = None
    amp_remote_write_endpoint: str | None = None

    # CDO-W12-020 Configs (S3 failure buffer & retry)
    delivery_mode: str = "aws"
    amp_delivery_enabled: bool = True
    amp_delivery_max_retries: int = 3
    amp_delivery_retry_base_delay_ms: int = 500
    amp_delivery_retry_max_delay_ms: int = 5000

    s3_failure_buffer_enabled: bool = True
    s3_failure_buffer_bucket: str = "cdo-telemetry-failure-buffer"
    s3_failure_buffer_prefix: str = "telemetry-failures/"
    s3_failure_buffer_kms_key_id: str | None = None
    s3_failure_buffer_object_age_alarm_seconds: int = 300

    cloudwatch_namespace: str = "CDO/TelemetryApi"


def _read_int(name: str, default: int) -> int:
    """Đọc biến môi trường kiểu số nguyên và báo lỗi rõ khi sai định dạng."""

    value = os.getenv(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc


def _read_bool(name: str, default: bool) -> bool:
    """Đọc biến môi trường kiểu boolean."""

    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in ("true", "1", "yes", "on")


def load_settings() -> Settings:
    """Nạp cấu hình Telemetry API từ biến môi trường của process."""

    # Cho phép TELEMETRY_API_PORT ghi đè PORT mặc định nếu được cung cấp
    port_env = os.getenv("TELEMETRY_API_PORT") or os.getenv("PORT")
    port = Settings.port
    if port_env is not None:
        try:
            port = int(port_env)
        except ValueError as exc:
            raise ValueError(f"PORT must be an integer") from exc

    app_mode = os.getenv("APP_MODE", "local")
    default_env = "prod" if app_mode == "aws" else "local"
    default_backend = "prometheus_amp" if app_mode == "aws" else "local_jsonl"

    return Settings(
        app_mode=app_mode,
        app_name=os.getenv("APP_NAME", Settings.app_name),
        app_version=os.getenv("APP_VERSION", Settings.app_version),
        build_id=os.getenv("BUILD_ID", Settings.build_id),
        git_commit_sha=os.getenv("GIT_COMMIT_SHA", Settings.git_commit_sha),
        env=os.getenv("ENV", default_env),
        port=port,
        max_ingest_payload_bytes=_read_int(
            "MAX_INGEST_PAYLOAD_BYTES",
            Settings.max_ingest_payload_bytes,
        ),
        telemetry_storage_backend=os.getenv(
            "TELEMETRY_STORAGE_BACKEND",
            default_backend,
        ),
        local_telemetry_file=os.getenv(
            "LOCAL_TELEMETRY_FILE",
            Settings.local_telemetry_file,
        ),
        log_level=os.getenv("LOG_LEVEL", Settings.log_level),
        app_metrics_enabled=_read_bool("APP_METRICS_ENABLED", Settings.app_metrics_enabled),
        prometheus_metrics_path=os.getenv("PROMETHEUS_METRICS_PATH", Settings.prometheus_metrics_path),
        aws_region=os.getenv("AWS_REGION", Settings.aws_region),
        amp_workspace_id=os.getenv("AMP_WORKSPACE_ID", Settings.amp_workspace_id),
        amp_remote_write_endpoint=os.getenv("AMP_REMOTE_WRITE_ENDPOINT", Settings.amp_remote_write_endpoint),
        delivery_mode=os.getenv("DELIVERY_MODE", Settings.delivery_mode),
        amp_delivery_enabled=_read_bool("AMP_DELIVERY_ENABLED", Settings.amp_delivery_enabled),
        amp_delivery_max_retries=_read_int("AMP_DELIVERY_MAX_RETRIES", Settings.amp_delivery_max_retries),
        amp_delivery_retry_base_delay_ms=_read_int("AMP_DELIVERY_RETRY_BASE_DELAY_MS", Settings.amp_delivery_retry_base_delay_ms),
        amp_delivery_retry_max_delay_ms=_read_int("AMP_DELIVERY_RETRY_MAX_DELAY_MS", Settings.amp_delivery_retry_max_delay_ms),
        s3_failure_buffer_enabled=_read_bool("S3_FAILURE_BUFFER_ENABLED", Settings.s3_failure_buffer_enabled),
        s3_failure_buffer_bucket=os.getenv("S3_FAILURE_BUFFER_BUCKET", Settings.s3_failure_buffer_bucket),
        s3_failure_buffer_prefix=os.getenv("S3_FAILURE_BUFFER_PREFIX", Settings.s3_failure_buffer_prefix),
        s3_failure_buffer_kms_key_id=os.getenv("S3_FAILURE_BUFFER_KMS_KEY_ID", Settings.s3_failure_buffer_kms_key_id),
        s3_failure_buffer_object_age_alarm_seconds=_read_int("S3_FAILURE_BUFFER_OBJECT_AGE_ALARM_SECONDS", Settings.s3_failure_buffer_object_age_alarm_seconds),
        cloudwatch_namespace=os.getenv("CLOUDWATCH_NAMESPACE", Settings.cloudwatch_namespace),
    )

