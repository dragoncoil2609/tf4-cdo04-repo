"""Session routes — manage AWS SSO profile lifecycle.

POST /api/session   — log in with a profile
GET  /api/session   — get current session info
DELETE /api/session — log out
POST /api/session/refresh — refresh current session
GET  /api/profiles  — list available AWS profiles
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel

from sre_dashboard.services.session import SessionManager

router = APIRouter()


class LoginRequest(BaseModel):
    profile: str | None = None
    region: str = "us-east-1"


@router.get("/api/profiles")
async def list_profiles(request: Request):
    mgr: SessionManager = request.app.state.session_manager
    return mgr.list_profiles()


@router.post("/api/session")
async def login(body: LoginRequest, request: Request):
    mgr: SessionManager = request.app.state.session_manager
    return mgr.login(profile=body.profile, region=body.region)


@router.get("/api/session")
async def get_session(request: Request):
    mgr: SessionManager = request.app.state.session_manager
    return mgr.get_state()


@router.delete("/api/session")
async def logout(request: Request):
    mgr: SessionManager = request.app.state.session_manager
    return mgr.logout()


@router.post("/api/session/refresh")
async def refresh_session(request: Request):
    mgr: SessionManager = request.app.state.session_manager
    return mgr.refresh()
