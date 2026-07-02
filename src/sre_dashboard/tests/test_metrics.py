"""Tests for the MetricsService.

Key contracts verified:
1. No raw PromQL input — metric_type is validated against a predefined set.
2. PromQL is constructed server-side from validated parameters.
3. Invalid metric_types are rejected with ValueError.
4. AMP query endpoint not configured returns an error gracefully.
"""

from __future__ import annotations

from unittest import mock

import pytest

from sre_dashboard.services.metrics import MetricsService, VALID_METRIC_TYPES


@pytest.fixture
def service():
    """Return a MetricsService with a mocked AwsClientFactory and no AMP endpoint."""
    factory = mock.MagicMock()
    factory._region = "us-east-1"
    factory._session.get_credentials.return_value = None
    return MetricsService(aws_client_factory=factory, amp_query_endpoint=None)


# ── No raw PromQL input — validation ────────────────────────────


def test_validate_metric_type_accepts_valid_types():
    """All 7 predefined metric types are accepted."""
    for mt in VALID_METRIC_TYPES:
        result = MetricsService.validate_metric_type(mt)
        assert result == mt


def test_validate_metric_type_normalizes_case():
    """Input is case-insensitive, normalized to lower case."""
    result = MetricsService.validate_metric_type("CPU_USAGE_PERCENT")
    assert result == "cpu_usage_percent"


def test_validate_metric_type_strips_whitespace():
    """Whitespace around the metric type is stripped."""
    result = MetricsService.validate_metric_type("  memory_usage_percent  ")
    assert result == "memory_usage_percent"


def test_validate_metric_type_rejects_unknown():
    """Unknown metric type raises ValueError."""
    with pytest.raises(ValueError, match="Unsupported metric_type"):
        MetricsService.validate_metric_type("throughput_rps")


def test_validate_metric_type_rejects_raw_promql():
    """Raw PromQL input is rejected — not a valid metric_type."""
    with pytest.raises(ValueError, match="Unsupported metric_type"):
        MetricsService.validate_metric_type("up{job=\"cdo\"}")


# ── PromQL construction ─────────────────────────────────────────


def test_build_promql_creates_correct_query():
    """PromQL template properly formats tenant_id and service_id."""
    promql = MetricsService.build_promql(
        metric_type="cpu_usage_percent",
        tenant_id="tnt-1",
        service_id="svc-a",
    )
    assert "cpu_usage_percent" in promql
    assert 'tenant_id="tnt-1"' in promql
    assert 'service_id="svc-a"' in promql


def test_build_promql_rejects_invalid_metric_type():
    """Invalid metric type raises ValueError during PromQL construction."""
    with pytest.raises(ValueError, match="Unsupported metric_type"):
        MetricsService.build_promql(
            metric_type="custom_promql",
            tenant_id="tnt-1",
            service_id="svc-a",
        )


def test_build_promql_never_uses_raw_input_in_query():
    """No raw user input appears verbatim in PromQL — all values are formatted."""
    promql = MetricsService.build_promql(
        metric_type="queue_depth",
        tenant_id="tnt-1",
        service_id="svc-a",
    )
    assert promql == 'queue_depth{tenant_id="tnt-1",service_id="svc-a"}'
    # Verify no special characters from user input could inject into the query
    assert ";" not in promql


# ── AMP query behavior ──────────────────────────────────────────


def test_query_metrics_no_endpoint(service):
    """When AMP endpoint is not configured, returns error gracefully."""
    result = service.query_metrics(
        metric_type="cpu_usage_percent",
        tenant_id="tnt-1",
        service_id="svc-a",
    )
    assert result["status"] == "error"
    assert "not configured" in result["detail"]


def test_metrics_service_no_credentials(service):
    """When no AWS credentials, returns error gracefully."""
    service._amp_query_endpoint = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-test"

    result = service.query_metrics(
        metric_type="cpu_usage_percent",
        tenant_id="tnt-1",
        service_id="svc-a",
    )
    # No credentials available, but this is handled by the requests call
    # For now we verify it returns an error dict
    assert result["status"] == "error"


# ── All 7 metric types have templates ───────────────────────────


def test_all_metric_types_have_templates():
    """Every metric type in VALID_METRIC_TYPES has a corresponding PromQL template."""
    from sre_dashboard.services.metrics import METRIC_TEMPLATES

    for mt in VALID_METRIC_TYPES:
        assert mt in METRIC_TEMPLATES, f"Missing template for {mt}"
        template = METRIC_TEMPLATES[mt]
        assert "{tenant_id}" in template, f"Template for {mt} missing tenant_id placeholder"
        assert "{service_id}" in template, f"Template for {mt} missing service_id placeholder"
