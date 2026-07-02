"""Policy routes — read and update service policies.

GET /api/policies?tenant_id=...
    — list policies, optionally filtered by tenant.

PUT /api/policies/{tenant_id}/{service_name}
    — update a policy's static_threshold with conditional write.
    Supports expected_old_value for optimistic concurrency.
"""

from __future__ import annotations

from fastapi import APIRouter, Request, HTTPException
from pydantic import BaseModel

router = APIRouter()


class PolicyUpdateRequest(BaseModel):
    static_threshold: float
    enabled: bool | None = None
    expected_old_value: float | None = None


@router.get("/api/policies")
async def list_policies(
    request: Request,
    tenant_id: str | None = None,
):
    """List all policies, optionally filtered by tenant."""
    ddb = request.app.state.dynamodb_service
    policies = ddb.list_policies(tenant_id=tenant_id)
    return {"tenant_id": tenant_id, "policies": policies}


@router.put("/api/policies/{tenant_id}/{service_name}")
async def update_policy(
    request: Request,
    tenant_id: str,
    service_name: str,
    body: PolicyUpdateRequest,
):
    """Update a policy threshold with conditional write.

    Validates threshold is 0-100. If expected_old_value is provided,
    the update only succeeds if the current value matches (optimistic
    concurrency via DynamoDB ConditionExpression).
    """
    ddb = request.app.state.dynamodb_service
    result = ddb.update_policy(
        tenant_id=tenant_id,
        service_name=service_name,
        static_threshold=body.static_threshold,
        enabled=body.enabled,
        expected_old_value=body.expected_old_value,
    )

    if result.get("status") == "error":
        raise HTTPException(status_code=400, detail=result.get("detail"))
    if result.get("status") == "conflict":
        raise HTTPException(status_code=409, detail=result.get("detail"))

    return result
