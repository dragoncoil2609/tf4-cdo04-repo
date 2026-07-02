"""Integration tests for SRE Dashboard API routes using TestClient.

These tests use mocked service dependencies to verify routing, status codes,
and response shapes without real AWS calls.
"""

from __future__ import annotations

from unittest import mock

import pytest
from fastapi.testclient import TestClient
from fastapi import FastAPI

from sre_dashboard.app import create_app
from sre_dashboard.settings import Settings


@pytest.fixture
def app():
    """Create a test app with mocked services."""
    settings = Settings(
        app_name="sre-dashboard",
        app_version="0.1.0",
        log_level="DEBUG",
        host="127.0.0.1",
        port=8001,
        aws_region="us-east-1",
    )
    test_app = create_app(settings=settings)

    # Override real services with mocks
    test_app.state.aws_client_factory = mock.MagicMock()
    test_app.state.dynamodb_service = mock.MagicMock()
    test_app.state.terraform_discovery = mock.MagicMock()
    test_app.state.session_manager = mock.MagicMock()
    test_app.state.metrics_service = mock.MagicMock()

    return test_app


@pytest.fixture
def client(app):
    return TestClient(app)


# ── Health ───────────────────────────────────────────────────────


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["service"] == "sre-dashboard"


# ── Session ──────────────────────────────────────────────────────


def test_get_profiles(client):
    client.app.state.session_manager.list_profiles.return_value = [
        {"name": "default", "source": "config"}
    ]
    resp = client.get("/api/profiles")
    assert resp.status_code == 200
    assert resp.json() == [{"name": "default", "source": "config"}]


def test_post_session(client):
    client.app.state.session_manager.login.return_value = {
        "status": "ok", "profile": "dev", "account_id": "123"
    }
    resp = client.post("/api/session", json={"profile": "dev"})
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_get_session(client):
    client.app.state.session_manager.get_state.return_value = {
        "is_logged_in": True, "profile": "dev"
    }
    resp = client.get("/api/session")
    assert resp.status_code == 200
    assert resp.json()["is_logged_in"] is True


def test_delete_session(client):
    client.app.state.session_manager.logout.return_value = {"status": "ok"}
    resp = client.delete("/api/session")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_refresh_session(client):
    client.app.state.session_manager.refresh.return_value = {"status": "ok"}
    resp = client.post("/api/session/refresh")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


# ── Probes ───────────────────────────────────────────────────────


def test_probes(client):
    client.app.state.terraform_discovery.discover.return_value = {}
    client.app.state.aws_client_factory.probe_sts.return_value = {"status": "ok", "account_id": "123"}
    client.app.state.aws_client_factory.probe_amp.return_value = {"status": "ok", "workspace_count": 1}
    client.app.state.aws_client_factory.probe_dynamodb.return_value = {"status": "ok", "table": "audit"}
    client.app.state.aws_client_factory.probe_cloudwatch.return_value = {"status": "ok", "alarm_count": 0}
    client.app.state.aws_client_factory.probe_ecs.return_value = {"status": "ok", "service_arns": []}

    resp = client.get("/api/probes")
    assert resp.status_code == 200
    data = resp.json()
    assert data["sts"]["status"] == "ok"
    assert data["amp"]["status"] == "ok"
    assert "sqs" in data  # skipped when no queue URL


# ── Tenants & Services & Overview ───────────────────────────────


def test_list_tenants(client):
    client.app.state.dynamodb_service.list_tenants.return_value = ["tnt-1", "tnt-2"]
    resp = client.get("/api/tenants")
    assert resp.status_code == 200
    assert resp.json()["tenants"] == ["tnt-1", "tnt-2"]


def test_list_services(client):
    client.app.state.dynamodb_service.list_services.return_value = ["svc-a", "svc-b"]
    resp = client.get("/api/services?tenant_id=tnt-1")
    assert resp.status_code == 200
    assert resp.json()["services"] == ["svc-a", "svc-b"]


def test_overview(client):
    client.app.state.dynamodb_service.get_overview.return_value = {
        "tenant_id": "tnt-1", "services": [], "errors": []
    }
    resp = client.get("/api/overview?tenant_id=tnt-1")
    assert resp.status_code == 200
    assert resp.json()["tenant_id"] == "tnt-1"


# ── Metrics ──────────────────────────────────────────────────────


def test_get_all_metrics(client):
    client.app.state.metrics_service._amp_query_endpoint = "https://amp.test"
    client.app.state.metrics_service.query_metrics.return_value = {
        "status": "ok", "series": []
    }
    resp = client.get("/api/metrics/svc-a?tenant_id=tnt-1&range_minutes=60")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["service_id"] == "svc-a"
    assert "metrics" in data


def test_get_single_metric(client):
    client.app.state.metrics_service._amp_query_endpoint = "https://amp.test"
    client.app.state.metrics_service.query_metrics.return_value = {
        "status": "ok", "metric_type": "cpu_usage_percent", "series": []
    }
    resp = client.get("/api/metrics/svc-a/cpu_usage_percent?tenant_id=tnt-1")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["metric_type"] == "cpu_usage_percent"


def test_get_single_metric_invalid_type_returns_400(client):
    resp = client.get("/api/metrics/svc-a/invalid_metric?tenant_id=tnt-1")
    assert resp.status_code == 400
    assert "Unsupported metric_type" in resp.json()["detail"]


# ── Audits ───────────────────────────────────────────────────────


def test_list_audits(client):
    client.app.state.dynamodb_service.query_audit_logs.return_value = [
        {"tenant_id": "tnt-1", "service_name": "svc-a", "decision": "KEEP_ALIVE"}
    ]
    resp = client.get("/api/audits?tenant_id=tnt-1")
    assert resp.status_code == 200
    data = resp.json()
    assert data["tenant_id"] == "tnt-1"
    assert data["count"] == 1


# ── Policies ─────────────────────────────────────────────────────


def test_list_policies(client):
    client.app.state.dynamodb_service.list_policies.return_value = [
        {"tenant_id": "tnt-1", "service_name": "svc-a", "static_threshold": 85}
    ]
    resp = client.get("/api/policies?tenant_id=tnt-1")
    assert resp.status_code == 200
    assert len(resp.json()["policies"]) == 1


def test_update_policy(client):
    client.app.state.dynamodb_service.update_policy.return_value = {
        "status": "ok",
        "tenant_id": "tnt-1",
        "service_name": "svc-a",
        "static_threshold": 70,
    }
    resp = client.put("/api/policies/tnt-1/svc-a", json={"static_threshold": 70})
    assert resp.status_code == 200
    assert resp.json()["static_threshold"] == 70


def test_update_policy_conflict(client):
    client.app.state.dynamodb_service.update_policy.return_value = {
        "status": "conflict",
        "detail": "Conditional check failed",
    }
    resp = client.put("/api/policies/tnt-1/svc-a", json={"static_threshold": 70, "expected_old_value": 85})
    assert resp.status_code == 409


# ── Alarms / Queue / ECS ────────────────────────────────────────


def test_list_alarms(client):
    client.app.state.aws_client_factory.list_alarms.return_value = [
        {"alarm_name": "cpu-high", "state_value": "ALARM"}
    ]
    resp = client.get("/api/alarms")
    assert resp.status_code == 200
    assert resp.json()["count"] == 1


def test_list_queues(client):
    client.app.state.aws_client_factory.list_queues.return_value = [
        {"queue_url": "https://sqs.aws.com/cdo-queue", "queue_name": "cdo-queue"}
    ]
    resp = client.get("/api/queue")
    assert resp.status_code == 200
    assert resp.json()["count"] == 1


def test_list_ecs(client):
    client.app.state.aws_client_factory.list_ecs_services.return_value = [
        {"service_name": "svc-a", "status": "ACTIVE"}
    ]
    resp = client.get("/api/ecs")
    assert resp.status_code == 200
    assert resp.json()["count"] == 1
