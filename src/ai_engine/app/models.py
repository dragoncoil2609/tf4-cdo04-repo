from pydantic import BaseModel, Field, field_validator
from typing import List, Optional, Dict, Any, Literal
from datetime import datetime
import uuid

# Canonical recommendation vocabulary. Single source of truth shared with
# ai-api-contract.md (Response body) and TF4 brief (line 33: scale / retire queue;
# line 45/87: action_verb + target + from->to + confidence + evidence_link).
ACTION_VERBS = ("SCALE_UP", "SCALE_DOWN", "RETIRE", "ROLLBACK", "INVESTIGATE")


class TimeRange(BaseModel):
    start_ts: datetime
    end_ts: datetime


class PredictContext(BaseModel):
    deployment_version: str
    time_range: TimeRange


class SignalDatapoint(BaseModel):
    ts: datetime
    tenant_id: str        # TF4 brief line 72: MANDATORY root field (multi-tenant isolation, must match X-Tenant-Id)
    service_id: str       # MANDATORY: maps each datapoint to its per-service baseline
    metric_type: str      # MANDATORY: metric dimension (e.g. cpu_usage_percent) — contract name, NOT "signal_name"
    value: float
    labels: Optional[Dict[str, Any]] = None


class PredictRequest(BaseModel):
    signal_window: List[SignalDatapoint] = Field(..., max_length=10000)
    context: PredictContext

    @field_validator("signal_window")
    @classmethod
    def check_window_size(cls, v: List[SignalDatapoint]) -> List[SignalDatapoint]:
        # Schema rule -> surfaces as HTTP 422 (ai-api-contract.md error table).
        if len(v) < 120:
            raise ValueError("signal_window must contain >= 120 datapoints (>= 120 minutes of context).")
        return v


class Recommendation(BaseModel):
    action_verb: Literal["SCALE_UP", "SCALE_DOWN", "RETIRE", "ROLLBACK", "INVESTIGATE"]
    target: str          # e.g., "payment-gw ECS Service"
    from_to: str         # e.g., "Current -> +2 Tasks"
    confidence: float = Field(ge=0.0, le=1.0)
    evidence_link: str   # e.g., "https://dashboard.internal/metrics/..."


class PredictResponse(BaseModel):
    anomaly: bool
    severity: float = Field(ge=0.0, le=1.0)
    recommendation: Optional[Recommendation] = None
    reasoning: str = Field(max_length=300)
    audit_id: uuid.UUID
