# -----------------------------------------------------------------------------
# TASK: CPOA-101 | CDO-W12-056 - AMP Quota & Cardinality Policy (Telemetry Ingestion)
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# Telemetry API Ingestion Server using FastAPI and Pydantic.
# Exposes POST /v1/telemetry to ingest metrics.
# Features:
# 1. Schema validation via Pydantic model.
# 2. Filtering of high-cardinality dynamic labels (denylist) to prevent AMP 
#    cardinality explosion (e.g. request_id, trace_id, prediction_id).
# 3. Non-blocking asynchronous OTLP conversion and forwarding to local ADOT
#    Collector OTLP/HTTP receiver using HTTPX AsyncClient.
# -----------------------------------------------------------------------------

import os
import uvicorn
import logging
import httpx  # Thay thế requests bằng httpx để tránh blocking I/O
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field, field_validator
from datetime import datetime
from typing import Dict, Any

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("telemetry_api")

app = FastAPI(title="CDO Telemetry Ingest API")

# Read ADOT collector endpoint from environment variable
OTEL_EXPORTER_OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")


class TelemetryPayload(BaseModel):
    ts: datetime
    tenant_id: str
    service_id: str
    metric_type: str
    value: float
    labels: Dict[str, Any] = Field(default_factory=dict)

    @field_validator("labels", mode="before")
    @classmethod
    def filter_dynamic_labels(cls, v: Any) -> Dict[str, Any]:
        """
        Lọc bỏ hoàn toàn các dynamic labels và high cardinality fields ra khỏi labels gửi đi
        để ngăn chặn tình trạng tràn quota và bùng nổ cardinality trên Amazon Managed Prometheus (AMP).
        """
        if not isinstance(v, dict):
            return {}

        # Denylist chứa các label động hoặc nhạy cảm có độ phân tán cao
        denylist = {
            "request_id",
            "trace_id",
            "prediction_id",
            "user_id",
            "transaction_id",
            "account_id",
            "card_pan",
        }

        filtered = {k: val for k, val in v.items() if k.lower() not in denylist}
        return filtered


def convert_to_otlp_json(payload: TelemetryPayload) -> Dict[str, Any]:
    """
    Chuyển đổi dữ liệu telemetry đã validate sang cấu trúc OTLP JSON format
    phù hợp để gửi tới OTLP/HTTP receiver của ADOT Collector.
    """
    time_unix_nano = int(payload.ts.timestamp() * 1e9)

    # Chuẩn bị danh sách attributes cho datapoint (nhãn metric)
    attributes = [
        {"key": "service_id", "value": {"stringValue": payload.service_id}},
        {"key": "tenant_id", "value": {"stringValue": payload.tenant_id}},
    ]
    for k, v in payload.labels.items():
        attributes.append({"key": k, "value": {"stringValue": str(v)}})

    otlp_payload = {
        "resourceMetrics": [
            {
                "resource": {
                    "attributes": [
                        {"key": "service.name", "value": {"stringValue": payload.service_id}},
                        {"key": "tenant_id", "value": {"stringValue": payload.tenant_id}},
                    ]
                },
                "scopeMetrics": [
                    {
                        "metrics": [
                            {
                                "name": payload.metric_type,
                                "gauge": {
                                    "dataPoints": [
                                        {
                                            "timeUnixNano": str(time_unix_nano),
                                            "asDouble": float(payload.value),
                                            "attributes": attributes,
                                        }
                                    ]
                                },
                            }
                        ]
                    }
                ],
            }
        ]
    }
    return otlp_payload


@app.get("/health")
@app.get("/")
def health_check():
    return {"status": "healthy"}


# Sử dụng async def để tối ưu hóa hiệu năng chịu tải
@app.post("/v1/telemetry", status_code=status.HTTP_202_ACCEPTED)
async def ingest_telemetry(payload: TelemetryPayload):
    otlp_payload = convert_to_otlp_json(payload)
    target_url = f"{OTEL_EXPORTER_OTLP_ENDPOINT}/v1/metrics"

    # Sử dụng Async Client để gửi non-blocking HTTP request
    async with httpx.AsyncClient() as client:
        try:
            logger.info(
                "Forwarding OTLP metric %s for tenant %s",
                payload.metric_type,
                payload.tenant_id,
            )
            response = await client.post(target_url, json=otlp_payload, timeout=5.0)
            if response.status_code not in (200, 201, 202):
                logger.error("ADOT Collector error: %s", response.status_code)
                raise HTTPException(
                    status_code=status.HTTP_502_BAD_GATEWAY,
                    detail="ADOT Collector rejected metrics payload",
                )
        except httpx.RequestError as e:
            logger.error("Cannot reach ADOT Collector: %s", str(e))
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"ADOT Collector unreachable: {str(e)}",
            )

    return {"status": "accepted", "metric": payload.metric_type}


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=8080)
