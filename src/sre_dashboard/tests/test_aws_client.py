"""Tests for AwsClientFactory.

Verifies that SQS only uses get_queue_attributes (not ReceiveMessage),
probes handle errors gracefully, and no credentials leak.
"""

from __future__ import annotations

from unittest import mock

import pytest

from sre_dashboard.services.aws_client import AwsClientFactory


@pytest.fixture
def factory():
    """Return an AwsClientFactory with a mocked boto3 session."""
    with mock.patch("boto3.Session") as mock_session:
        mock_session_instance = mock.MagicMock()
        mock_session.return_value = mock_session_instance
        f = AwsClientFactory(region="us-east-1")
        yield f


# ── SQS: no ReceiveMessage ──────────────────────────────────────


def test_sqs_probe_uses_get_queue_attributes_not_receive_message(factory):
    """SQS probe must only call get_queue_attributes, never ReceiveMessage."""
    mock_sqs = mock.MagicMock()
    mock_sqs.get_queue_attributes.return_value = {
        "Attributes": {
            "ApproximateNumberOfMessages": "42",
            "ApproximateNumberOfMessagesNotVisible": "3",
        }
    }
    factory._session.client.return_value = mock_sqs

    result = factory.probe_sqs("https://sqs.us-east-1.amazonaws.com/123/test-queue")

    assert result["status"] == "ok"
    assert result["approximate_number_of_messages"] == 42
    assert result["approximate_number_of_messages_not_visible"] == 3

    # Verify get_queue_attributes was called
    mock_sqs.get_queue_attributes.assert_called_once_with(
        QueueUrl="https://sqs.us-east-1.amazonaws.com/123/test-queue",
        AttributeNames=["All"],
    )
    # Verify ReceiveMessage was NEVER called
    mock_sqs.receive_message.assert_not_called()


def test_sqs_list_queues_uses_get_queue_attributes_not_receive_message(factory):
    """list_queues must never call ReceiveMessage."""
    mock_sqs = mock.MagicMock()
    mock_sqs.list_queues.return_value = {
        "QueueUrls": ["https://sqs.us-east-1.amazonaws.com/123/cdo-queue"]
    }
    mock_sqs.get_queue_attributes.return_value = {
        "Attributes": {
            "ApproximateNumberOfMessages": "5",
            "ApproximateNumberOfMessagesNotVisible": "1",
        }
    }
    factory._session.client.return_value = mock_sqs

    queues = factory.list_queues(prefix="cdo")

    assert len(queues) == 1
    assert queues[0]["queue_name"] == "cdo-queue"
    mock_sqs.receive_message.assert_not_called()


# ── STS probe ───────────────────────────────────────────────────


def test_sts_probe_ok(factory):
    mock_sts = mock.MagicMock()
    mock_sts.get_caller_identity.return_value = {
        "Account": "123456789012",
        "Arn": "arn:aws:iam::123456789012:user/test-user",
    }
    factory._session.client.return_value = mock_sts

    result = factory.probe_sts()
    assert result["status"] == "ok"
    assert result["account_id"] == "123456789012"


def test_sts_probe_error(factory):
    mock_sts = mock.MagicMock()
    mock_sts.get_caller_identity.side_effect = Exception("Network error")
    factory._session.client.return_value = mock_sts

    result = factory.probe_sts()
    assert result["status"] == "error"
    assert "Network error" in result["detail"]


# ── DynamoDB probe ──────────────────────────────────────────────


def test_dynamodb_probe_ok(factory):
    mock_ddb = mock.MagicMock()
    factory._session.client.return_value = mock_ddb

    result = factory.probe_dynamodb("cdo04-audit-logs")
    assert result["status"] == "ok"
    assert result["table"] == "cdo04-audit-logs"


def test_dynamodb_probe_access_denied(factory):
    from botocore.exceptions import ClientError

    mock_ddb = mock.MagicMock()
    mock_ddb.describe_table.side_effect = ClientError(
        {"Error": {"Code": "AccessDeniedException", "Message": "Access denied"}},
        "DescribeTable",
    )
    factory._session.client.return_value = mock_ddb

    result = factory.probe_dynamodb("cdo04-audit-logs")
    assert result["status"] == "denied"


# ── AMP probe ───────────────────────────────────────────────────


def test_amp_probe_ok(factory):
    mock_amp = mock.MagicMock()
    mock_amp.list_workspaces.return_value = {"workspaces": [{"alias": "cdo-amp"}]}
    factory._session.client.return_value = mock_amp

    result = factory.probe_amp()
    assert result["status"] == "ok"
    assert result["workspace_count"] == 1


def test_amp_probe_error(factory):
    mock_amp = mock.MagicMock()
    mock_amp.list_workspaces.side_effect = Exception("Access denied")
    factory._session.client.return_value = mock_amp

    result = factory.probe_amp()
    assert result["status"] == "error"


# ── CloudWatch probe ────────────────────────────────────────────


def test_cloudwatch_probe_ok(factory):
    mock_cw = mock.MagicMock()
    mock_cw.describe_alarms.return_value = {"MetricAlarms": [{"AlarmName": "cpu-high"}]}
    factory._session.client.return_value = mock_cw

    result = factory.probe_cloudwatch()
    assert result["status"] == "ok"
    assert result["alarm_count"] == 1


# ── ECS probe ───────────────────────────────────────────────────


def test_ecs_probe_ok(factory):
    mock_ecs = mock.MagicMock()
    mock_ecs.list_services.return_value = {"serviceArns": ["arn:aws:ecs:...:service/cluster/svc-a"]}
    factory._session.client.return_value = mock_ecs

    result = factory.probe_ecs()
    assert result["status"] == "ok"
    assert len(result["service_arns"]) == 1


# ── No credentials leak ─────────────────────────────────────────


def test_no_credentials_in_return_values(factory):
    """Verify that probe return values never contain secret/credential fields."""
    mock_sts = mock.MagicMock()
    mock_sts.get_caller_identity.return_value = {
        "Account": "123456789012",
        "Arn": "arn:aws:iam::123456789012:user/test-user",
    }
    factory._session.client.return_value = mock_sts

    result = factory.probe_sts()
    # No credential-like keys
    for key in ("secret_key", "SecretKey", "access_key", "AccessKey", "token", "session_token"):
        assert key not in result
