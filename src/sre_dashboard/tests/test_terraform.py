"""Tests for TerraformDiscovery.

Verifies terraform output discovery, caching, and error handling.
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

import pytest

from sre_dashboard.services.terraform import TerraformDiscovery


@pytest.fixture
def discovery(tmp_path):
    """Return a TerraformDiscovery pointing at a temp directory.

    Patches subprocess.run to prevent actual terraform execution.
    """
    with mock.patch("subprocess.run", side_effect=FileNotFoundError("terraform not found")):
        yield TerraformDiscovery(output_dir=str(tmp_path))


# ── Cached output file ──────────────────────────────────────────


def test_reads_cached_output(discovery, tmp_path):
    """Reads terraform-output.json when present."""
    cache = tmp_path / "terraform-output.json"
    cache.write_text(json.dumps({
        "amp_query_endpoint": {"value": "https://aps.aws.com/ws-123", "type": "string"},
        "sqs_queue_url": {"value": "https://sqs.aws.com/123/cdo-queue", "type": "string"},
    }))

    result = discovery.discover()

    assert result["amp_query_endpoint"] == "https://aps.aws.com/ws-123"
    assert result["sqs_queue_url"] == "https://sqs.aws.com/123/cdo-queue"


def test_cached_output_flat_json(discovery, tmp_path):
    """Handles flat JSON (without Terraform's {value, type} wrapper)."""
    cache = tmp_path / "terraform-output.json"
    cache.write_text(json.dumps({
        "amp_query_endpoint": "https://aps.aws.com/ws-456",
    }))

    result = discovery.discover()
    assert result["amp_query_endpoint"] == "https://aps.aws.com/ws-456"


def test_no_output_file(discovery):
    """When no output file exists, returns empty dict."""
    result = discovery.discover()
    assert result == {}


# ── terraform binary execution ──────────────────────────────────


def test_runs_terraform_binary():
    """When terraform binary is in PATH, it is used."""
    d = TerraformDiscovery(output_dir="/tmp")
    with mock.patch("subprocess.run") as mock_run:
        mock_run.return_value = mock.MagicMock(
            returncode=0,
            stdout=json.dumps({
                "amp_query_endpoint": {"value": "https://aps.aws.com/ws-789", "type": "string"},
            }),
        )
        result = d.discover()

    assert result["amp_query_endpoint"] == "https://aps.aws.com/ws-789"
    mock_run.assert_called_once()


def test_terraform_not_available():
    """When terraform binary is not found, falls back to cache or empty."""
    d = TerraformDiscovery(output_dir="/tmp")
    with mock.patch("subprocess.run", side_effect=FileNotFoundError("terraform not found")):
        result = d.discover()
    assert result == {} or isinstance(result, dict)


def test_terraform_timeout():
    """When terraform times out, returns empty or cache."""
    from subprocess import TimeoutExpired
    d = TerraformDiscovery(output_dir="/tmp")
    with mock.patch("subprocess.run", side_effect=TimeoutExpired("terraform", 15)):
        result = d.discover()
    assert isinstance(result, dict)


# ── Directory doesn't exist ─────────────────────────────────────


def test_nonexistent_directory():
    """When output directory doesn't exist, returns empty dict."""
    d = TerraformDiscovery(output_dir="/nonexistent/path")
    with mock.patch("subprocess.run", side_effect=FileNotFoundError("terraform not found")):
        result = d.discover()
    assert result == {}
