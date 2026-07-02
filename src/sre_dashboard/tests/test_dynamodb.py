"""Tests for DynamoDbService.

Key contracts verified:
1. Policy update validates threshold 0-100.
2. Conditional update with expected_old_value.
3. No delete operations exposed.
"""

from __future__ import annotations

from unittest import mock
from decimal import Decimal

import pytest
from botocore.exceptions import ClientError

from sre_dashboard.services.dynamodb import DynamoDbService


@pytest.fixture
def service():
    """Return a DynamoDbService with mocked boto3 session and tables."""
    with mock.patch("boto3.Session") as mock_session:
        mock_session_instance = mock.MagicMock()
        mock_session.return_value = mock_session_instance
        mock_dynamodb = mock.MagicMock()
        mock_session_instance.resource.return_value = mock_dynamodb
        mock_audit_table = mock.MagicMock()
        mock_policy_table = mock.MagicMock()
        mock_dynamodb.Table.side_effect = lambda name: {
            "cdo04-audit-logs": mock_audit_table,
            "cdo04-service-policies": mock_policy_table,
        }.get(name, mock.MagicMock())

        svc = DynamoDbService(
            audit_table_name="cdo04-audit-logs",
            policy_table_name="cdo04-service-policies",
            region="us-east-1",
        )
        svc._audit_table = mock_audit_table
        svc._policy_table = mock_policy_table
        yield svc


# ── Policy update: threshold validation 0-100 ───────────────────


def test_update_policy_validates_threshold_range(service):
    """Threshold must be 0-100, otherwise returns error."""
    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=150,
    )
    assert result["status"] == "error"
    assert "0-100" in result["detail"]


def test_update_policy_negative_threshold_rejected(service):
    """Negative threshold is rejected."""
    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=-5,
    )
    assert result["status"] == "error"


def test_update_policy_accepts_valid_threshold(service):
    """Threshold 0-100 is accepted and update_item is called."""
    service._policy_table.update_item.return_value = {
        "Attributes": {
            "tenant_id": "tnt-1",
            "service_name": "svc-a",
            "static_threshold": Decimal("75"),
            "enabled": True,
        }
    }

    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=75,
    )
    assert result["status"] == "ok"
    assert result["static_threshold"] == 75.0


# ── Conditional update with expected_old_value ──────────────────


def test_update_policy_with_expected_old_value_success(service):
    """When expected_old_value matches, update succeeds."""
    service._policy_table.update_item.return_value = {
        "Attributes": {
            "tenant_id": "tnt-1",
            "service_name": "svc-a",
            "static_threshold": Decimal("80"),
            "enabled": True,
        }
    }

    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=80,
        expected_old_value=75,
    )

    assert result["status"] == "ok"
    # Verify ConditionExpression was passed
    _, kwargs = service._policy_table.update_item.call_args
    assert "ConditionExpression" in kwargs
    assert "static_threshold = :expected" in kwargs["ConditionExpression"]


def test_update_policy_with_expected_old_value_conflict(service):
    """When expected_old_value doesn't match, returns conflict."""
    from botocore.exceptions import ClientError

    service._policy_table.update_item.side_effect = ClientError(
        {"Error": {"Code": "ConditionalCheckFailedException", "Message": "Condition failed"}},
        "UpdateItem",
    )

    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=80,
        expected_old_value=75,
    )

    assert result["status"] == "conflict"
    assert "expected_old_value" in result["detail"]


def test_update_policy_without_expected_old_value(service):
    """When expected_old_value is None, still require existing policy item."""
    service._policy_table.update_item.return_value = {
        "Attributes": {
            "tenant_id": "tnt-1",
            "service_name": "svc-a",
            "static_threshold": Decimal("85"),
            "enabled": True,
        }
    }

    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=85,
    )

    assert result["status"] == "ok"
    _, kwargs = service._policy_table.update_item.call_args
    assert "ConditionExpression" in kwargs
    assert "attribute_exists(tenant_id)" in kwargs["ConditionExpression"]
    assert "attribute_exists(service_name)" in kwargs["ConditionExpression"]


# ── ClientError passthrough ─────────────────────────────────────


def test_update_policy_other_client_error(service):
    """Non-ConditionalCheck ClientError returns error, not crash."""
    from botocore.exceptions import ClientError

    service._policy_table.update_item.side_effect = ClientError(
        {"Error": {"Code": "ValidationException", "Message": "Bad request"}},
        "UpdateItem",
    )

    result = service.update_policy(
        tenant_id="tnt-1",
        service_name="svc-a",
        static_threshold=50,
    )
    assert result["status"] == "error"


# ── No delete operations ────────────────────────────────────────


def test_no_delete_methods():
    """DynamoDbService should not expose delete_item."""
    svc_methods = [m for m in dir(DynamoDbService) if not m.startswith("_")]
    delete_methods = [m for m in svc_methods if "delete" in m.lower()]
    assert len(delete_methods) == 0, f"Delete methods found: {delete_methods}"
