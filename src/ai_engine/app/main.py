from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from typing import Optional
import uuid
import time
from collections import defaultdict

from .models import PredictRequest, PredictResponse
from .engine import AnomalyDetector
from .audit import AuditLogger

app = FastAPI(title="Foresight Lens AI Engine", version="v1.0")
detector = AnomalyDetector()
audit_logger = AuditLogger()

# Error model (ai-api-contract.md):
#   422 - schema/type validation failure (missing field, wrong type, signal_window < 120).
#         Handled natively by FastAPI/Pydantic; we deliberately do NOT downgrade it to 400.
#   400 - well-formed but invalid input (tenant_id mismatch, data gap).
#   401 - missing X-Tenant-Id. 429 - rate limit. 503 - engine unavailable.

RATE_LIMIT_PER_MIN = 600  # ai-api-contract.md: 600 requests/minute/tenant
request_counts = defaultdict(list)


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    tenant_id = request.headers.get("x-tenant-id")
    if tenant_id:
        now = time.time()
        request_counts[tenant_id] = [t for t in request_counts[tenant_id] if now - t < 60]
        if len(request_counts[tenant_id]) >= RATE_LIMIT_PER_MIN:
            return JSONResponse(status_code=429, content={"detail": "Rate limit exceeded"},
                                headers={"Retry-After": "60"})
        request_counts[tenant_id].append(now)

    return await call_next(request)


@app.get("/health")
async def health_check():
    return {"status": "healthy", "version": "v1.0"}


@app.post("/v1/predict", response_model=PredictResponse)
async def predict_capacity(
    request: PredictRequest,
    x_tenant_id: Optional[str] = Header(None, alias="X-Tenant-Id"),
    authorization: Optional[str] = Header(None, alias="Authorization"),
    x_correlation_id: Optional[str] = Header(None, alias="X-Correlation-Id"),
):
    if not x_tenant_id:
        raise HTTPException(status_code=401, detail="X-Tenant-Id header is required")

    if not x_correlation_id:
        x_correlation_id = str(uuid.uuid4())

    # Business validation (schema/type already enforced by Pydantic -> 422)
    prev_ts = None
    for dp in request.signal_window:
        # Multi-tenant isolation: every datapoint's tenant_id must match the header.
        if dp.tenant_id != x_tenant_id:
            raise HTTPException(status_code=400,
                                detail="tenant_id in signal datapoint does not match X-Tenant-Id header")
        # Continuity check (assumes 1-minute interval, 5s tolerance).
        current_ts = dp.ts.timestamp()
        if prev_ts is not None and current_ts - prev_ts > 65:
            raise HTTPException(status_code=400,
                                detail="Missing data detected (gap > 1 minute). Data must be continuous.")
        prev_ts = current_ts

    # Detect drift using STL-baseline + EWMA control chart
    anomaly, severity, suggested_action, reasoning, confidence = detector.detect_drift(
        tenant_id=x_tenant_id,
        signals=request.signal_window,
    )

    # Confidence gating MG-03: low-confidence recommendations are downgraded to INVESTIGATE.
    if suggested_action and confidence < 0.7:
        suggested_action["action_verb"] = "INVESTIGATE"

    response_data = {
        "anomaly": anomaly,
        "severity": severity,
        "recommendation": suggested_action,
        "reasoning": reasoning,
    }

    # IAM SigV4 is enforced at the edge by a CDO-hosted private API Gateway (AWS_IAM
    # authorization) in front of the internal ALB (SG-to-SG private subnet), NOT in app
    # code. Requests reaching here are already signed & verified; we only read the verified
    # principal_id for the audit log. Authorization stays Optional by design (W11 mock /
    # edge owns enforcement).
    principal_id = (authorization.split("Credential=")[-1].split("/")[0]
                    if authorization and "Credential=" in authorization else "mock-principal-id")

    request_data = request.model_dump()
    request_data["principal_id"] = principal_id

    audit_id = audit_logger.log_decision(x_tenant_id, request_data, response_data)

    return PredictResponse(
        anomaly=anomaly,
        severity=severity,
        recommendation=suggested_action,
        reasoning=reasoning,
        audit_id=audit_id,
    )
