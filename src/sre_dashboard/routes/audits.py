"""Audit log routes.

GET /api/audits?tenant_id=...&service_id=...&limit=50
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request

router = APIRouter()


@router.get("/api/audits")
async def list_audits(
    request: Request,
    tenant_id: str = Query(..., description="Tenant ID to filter audits by"),
    service_id: str | None = Query(None, description="Optional service name filter"),
    limit: int = Query(50, description="Maximum number of audit records to return"),
):
    """Query audit logs for a tenant, optionally filtered by service."""
    ddb = request.app.state.dynamodb_service
    records = ddb.query_audit_logs(
        tenant_id=tenant_id,
        service_id=service_id,
        limit=limit,
    )
    return {
        "tenant_id": tenant_id,
        "service_id": service_id,
        "count": len(records),
        "records": records,
    }
