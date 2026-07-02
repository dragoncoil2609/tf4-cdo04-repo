"""Tests for SessionManager.

Verifies session lifecycle: login, logout, refresh, list_profiles.
"""

from __future__ import annotations

from unittest import mock

import pytest

from sre_dashboard.services.session import SessionManager


@pytest.fixture
def manager():
    return SessionManager()


# ── Initial state ───────────────────────────────────────────────


def test_initial_state_is_logged_out(manager):
    state = manager.get_state()
    assert state["is_logged_in"] is False
    assert state["profile"] is None


# ── Login ────────────────────────────────────────────────────────


def test_login_success(manager):
    with mock.patch("boto3.Session") as mock_session:
        mock_session_instance = mock.MagicMock()
        mock_session.return_value = mock_session_instance
        mock_sts = mock.MagicMock()
        mock_sts.get_caller_identity.return_value = {
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/test-user",
        }
        mock_session_instance.client.return_value = mock_sts

        result = manager.login(profile="test-profile", region="us-east-1")

    assert result["status"] == "ok"
    assert result["account_id"] == "123456789012"
    assert manager.get_state()["is_logged_in"] is True


def test_login_failure_returns_error(manager):
    with mock.patch("boto3.Session") as mock_session:
        mock_session.side_effect = Exception("Profile not found")

        result = manager.login(profile="missing-profile")

    assert result["status"] == "error"
    assert "sso login" in result["detail"].lower()
    assert manager.get_state()["is_logged_in"] is False


# ── Logout ───────────────────────────────────────────────────────


def test_logout_clears_state(manager):
    # First login
    with mock.patch("boto3.Session") as mock_session:
        mock_session_instance = mock.MagicMock()
        mock_session.return_value = mock_session_instance
        mock_sts = mock.MagicMock()
        mock_sts.get_caller_identity.return_value = {
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/test-user",
        }
        mock_session_instance.client.return_value = mock_sts
        manager.login(profile="test-profile")

    assert manager.get_state()["is_logged_in"] is True

    # Then logout
    result = manager.logout()
    assert result["status"] == "ok"
    assert manager.get_state()["is_logged_in"] is False


# ── Refresh ──────────────────────────────────────────────────────


def test_refresh_no_active_session(manager):
    result = manager.refresh()
    assert result["status"] == "error"
    assert "No active session" in result["detail"]


def test_refresh_success(manager):
    with mock.patch("boto3.Session") as mock_session:
        mock_session_instance = mock.MagicMock()
        mock_session.return_value = mock_session_instance
        mock_sts = mock.MagicMock()
        mock_sts.get_caller_identity.return_value = {
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/test-user",
        }
        mock_session_instance.client.return_value = mock_sts
        manager.login(profile="test-profile")
        mock_sts.reset_mock()

        # Second call for refresh returns same identity
        mock_sts.get_caller_identity.return_value = {
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/test-user",
        }
        result = manager.refresh()

    assert result["status"] == "ok"
    assert result["account_id"] == "123456789012"


# ── List profiles ────────────────────────────────────────────────


def test_list_profiles_no_aws_dir(manager):
    """When ~/.aws doesn't exist, returns empty list."""
    with mock.patch("os.path.isfile", return_value=False):
        profiles = manager.list_profiles()
    assert profiles == []


def test_list_profiles_parses_config(manager):
    """Parses [profile ...] sections from AWS config."""
    config_content = """[default]
region = us-east-1
[profile dev]
region = us-west-2
[profile prod]
region = eu-west-1
"""
    with mock.patch("os.path.isfile", return_value=True), \
         mock.patch("builtins.open", mock.mock_open(read_data=config_content)):
        profiles = manager.list_profiles()

    names = {p["name"] for p in profiles}
    assert "default" in names
    assert "dev" in names
    assert "prod" in names
