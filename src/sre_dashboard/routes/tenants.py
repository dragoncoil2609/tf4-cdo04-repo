"""Tenant and service discovery routes.

GET /api/tenants           — list all tenants
GET /api/services          — list services for a tenant
GET /api/overview          — aggregated overview for a tenant
"""

from __future__ import annotations

from fastapi import APIRouter, Query, Request

router = APIRouter()


@router.get("/api/tenants")
async def list_tenants(request: Request):
    """List all known tenants from the audit and policy tables."""
    ddb = request.app.state.dynamodb_service
    return {"tenants": ddb.list_tenants()}


@router.get("/api/services")
async def list_services(
    request: Request,
    tenant_id: str = Query(..., description="Tenant ID to filter services by"),
):
    """List services for a given tenant."""
    ddb = request.app.state.dynamodb_service
    return {"tenant_id": tenant_id, "services": ddb.list_services(tenant_id)}


@router.get("/api/overview")
async def overview(
    request: Request,
    tenant_id: str = Query(..., description="Tenant ID to get overview for"),
):
    """Get aggregated overview for a tenant."""
    ddb = request.app.state.dynamodb_service
    return ddb.get_overview(tenant_id)
