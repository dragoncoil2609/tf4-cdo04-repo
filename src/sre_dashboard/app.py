"""SRE Dashboard FastAPI application factory.

Wires together routes, services, and settings for the local-only operational
visibility dashboard.
"""

from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI

from sre_dashboard.settings import Settings, load_settings
from sre_dashboard.services.aws_client import AwsClientFactory
from sre_dashboard.services.dynamodb import DynamoDbService
from sre_dashboard.services.metrics import MetricsService
from sre_dashboard.services.session import SessionManager
from sre_dashboard.services.terraform import TerraformDiscovery
from sre_dashboard.routes.health import router as health_router
from sre_dashboard.routes.session import router as session_router
from sre_dashboard.routes.probes import router as probes_router
from sre_dashboard.routes.tenants import router as tenants_router
from sre_dashboard.routes.metrics import router as metrics_router
from sre_dashboard.routes.audits import router as audits_router
from sre_dashboard.routes.policies import router as policies_router
from sre_dashboard.routes.alarms import router as alarms_router

logger = logging.getLogger("sre_dashboard.app")


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create and configure the SRE Dashboard FastAPI application."""
    resolved = settings or load_settings()

    # Configure logging
    logging.basicConfig(
        level=getattr(logging, resolved.log_level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    app = FastAPI(
        title="CDO SRE Dashboard",
        version=resolved.app_version,
        description="Local-only operational visibility for CDO capacity management",
    )

    # ── Instantiate services ─────────────────────────────────────
    terraform_discovery = TerraformDiscovery(
        output_dir=resolved.terraform_output_dir,
    )
    tf_outputs = terraform_discovery.discover()

    aws_client_factory = AwsClientFactory(
        region=resolved.aws_region,
        profile=resolved.aws_profile,
    )
    dynamodb_service = DynamoDbService(
        audit_table_name=tf_outputs.get("audit_table_name") or resolved.audit_table_name,
        policy_table_name=tf_outputs.get("policy_table_name") or resolved.policy_table_name,
        region=resolved.aws_region,
        profile=resolved.aws_profile,
    )
    session_manager = SessionManager()

    amp_query_endpoint = tf_outputs.get("amp_query_endpoint") or tf_outputs.get(
        "amp_workspace_url"
    )
    metrics_service = MetricsService(
        aws_client_factory=aws_client_factory,
        amp_query_endpoint=amp_query_endpoint,
    )

    # ── Store on app state ───────────────────────────────────────
    app.state.settings = resolved
    app.state.aws_client_factory = aws_client_factory
    app.state.dynamodb_service = dynamodb_service
    app.state.terraform_discovery = terraform_discovery
    app.state.session_manager = session_manager
    app.state.metrics_service = metrics_service

    # ── Register routes ──────────────────────────────────────────
    app.include_router(health_router)
    app.include_router(session_router)
    app.include_router(probes_router)
    app.include_router(tenants_router)
    app.include_router(metrics_router)
    app.include_router(audits_router)
    app.include_router(policies_router)
    app.include_router(alarms_router)

    return app


# Module-level default for `uvicorn sre_dashboard.app:app`
app = create_app()
