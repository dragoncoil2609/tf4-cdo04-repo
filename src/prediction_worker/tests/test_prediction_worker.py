"""
Tests for prediction_worker/app.py — Batch 2-5 local tests.
Strategy: monkeypatch boto3 before import to avoid AWS network calls.
"""

import sys
import os
from decimal import Decimal
from unittest import mock
from datetime import datetime, timezone

import pytest

# ── Module-level monkeypatch BEFORE import ──────────────────────────
# boto3.client and boto3.resource are called at module level in app.py.
# We patch them with MagicMock instances so no real AWS calls fire.

_mock_sqs = mock.MagicMock()
_mock_dynamodb = mock.MagicMock()
_mock_sns = mock.MagicMock()
_mock_audit_table = mock.MagicMock()
_mock_policy_table = mock.MagicMock()

# Set up the resource chain: dynamodb.Table(...) returns the mock tables.
_mock_dynamodb.Table.side_effect = lambda name: {
    "cdo04-audit-logs": _mock_audit_table,
    "cdo04-service-policies": _mock_policy_table,
}.get(name, mock.MagicMock())

os.environ["AWS_REGION"] = "us-east-1"
os.environ["SQS_QUEUE_URL"] = "https://sqs.us-east-1.amazonaws.com/123456789/test-queue"
os.environ["AMP_QUERY_ENDPOINT"] = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-test"
os.environ["AI_ENGINE_ENDPOINT"] = "http://ai-engine.cdo-services/v1/predict"
os.environ["DYNAMODB_AUDIT_TABLE"] = "cdo04-audit-logs"
os.environ["DYNAMODB_POLICY_TABLE"] = "cdo04-service-policies"
os.environ["ALERT_TOPIC_ARN"] = "arn:aws:sns:us-east-1:123456789:test-topic"

with mock.patch("boto3.client") as mock_client, mock.patch("boto3.resource") as mock_resource:
    mock_client.side_effect = lambda service, **kwargs: {
        "sqs": _mock_sqs,
        "sns": _mock_sns,
    }.get(service, mock.MagicMock())
    mock_resource.return_value = _mock_dynamodb

    # Must add the src dir to path so the relative import mechanism works.
    _test_dir = os.path.dirname(__file__)                              # .../prediction_worker/tests
    _src_dir = os.path.join(_test_dir, "..", "..")                     # .../src
    _src_dir = os.path.abspath(_src_dir)
    if _src_dir not in sys.path:
        sys.path.insert(0, _src_dir)

    from prediction_worker.app import (
        align_and_impute,
        get_static_threshold_fallback,
        save_audit_log,
        process_job,
    )


# ══════════════════════════════════════════════════════════════════════
# align_and_impute  —  CPOA-63 | CDO-W12-022
# ══════════════════════════════════════════════════════════════════════

class TestAlignAndImpute:
    """Bucket alignment + imputation with forward_fill / zero_fill."""

    _START = 1719705600   # 2024-06-30T00:00:00Z (example epoch)
    _STEP = 60
    _COUNT = 10           # 10 buckets for readable assertions

    @staticmethod
    def _make_raw(values_by_ts):
        """values_by_ts: dict {timestamp_int: float}"""
        return [{"values": [(ts, val) for ts, val in sorted(values_by_ts.items())]}]

    def test_complete_no_gaps(self):
        """All expected timestamps present -> gap_ratio = 0.0, values match."""
        raw = self._make_raw({self._START + i * self._STEP: float(i * 10) for i in range(self._COUNT)})
        end = self._START + (self._COUNT - 1) * self._STEP

        aligned, gap = align_and_impute(raw, self._START, end, step_seconds=self._STEP,
                                         fill_policy="forward_fill")

        assert gap == 0.0
        assert len(aligned) == self._COUNT
        for i in range(self._COUNT):
            ts = self._START + i * self._STEP
            assert aligned[ts] == float(i * 10)

    def test_off_minute_window_aligns_to_amp_buckets(self):
        """Off-minute worker windows must match minute-bucketed AMP points."""
        raw = self._make_raw({self._START + i * self._STEP: float(i * 10) for i in range(self._COUNT)})
        start = self._START + 42
        end = self._START + (self._COUNT - 1) * self._STEP + 42

        aligned, gap = align_and_impute(raw, start, end, step_seconds=self._STEP,
                                         fill_policy="forward_fill")

        assert gap == 0.0
        assert len(aligned) == self._COUNT
        assert aligned[self._START] == 0.0
        assert aligned[self._START + 9 * self._STEP] == 90.0

    def test_missing_forward_fill(self):
        """Middle bucket missing -> forward_fill repeats last known value."""
        raw = self._make_raw({
            self._START + 0 * self._STEP: 10.0,
            # self._START + 1 * self._STEP  <-- intentionally missing
            self._START + 2 * self._STEP: 30.0,
            self._START + 3 * self._STEP: 40.0,
        })
        end = self._START + 3 * self._STEP

        aligned, gap = align_and_impute(raw, self._START, end, step_seconds=self._STEP,
                                         fill_policy="forward_fill")

        assert aligned[self._START + 0 * self._STEP] == 10.0
        assert aligned[self._START + 1 * self._STEP] == 10.0   # filled by forward_fill
        assert aligned[self._START + 2 * self._STEP] == 30.0
        assert aligned[self._START + 3 * self._STEP] == 40.0
        assert gap == pytest.approx(1.0 / 4)  # 1 missing out of 4

    def test_missing_zero_fill(self):
        """Middle bucket missing -> zero_fill uses 0.0 regardless of prior value."""
        raw = self._make_raw({
            self._START + 0 * self._STEP: 10.0,
            # self._START + 1 * self._STEP  <-- missing
            self._START + 2 * self._STEP: 30.0,
        })
        end = self._START + 2 * self._STEP

        aligned, gap = align_and_impute(raw, self._START, end, step_seconds=self._STEP,
                                         fill_policy="zero_fill")

        assert aligned[self._START + 0 * self._STEP] == 10.0
        assert aligned[self._START + 1 * self._STEP] == 0.0    # zero-filled
        assert aligned[self._START + 2 * self._STEP] == 30.0
        assert gap == pytest.approx(1.0 / 3)

    def test_empty_raw(self):
        """No AMP data at all -> every bucket zero-filled, gap_ratio = 1.0."""
        raw = []
        end = self._START + 4 * self._STEP

        aligned, gap = align_and_impute(raw, self._START, end, step_seconds=self._STEP,
                                         fill_policy="forward_fill")

        assert gap == 1.0
        assert len(aligned) == 5
        for ts in aligned:
            assert aligned[ts] == 0.0

    def test_no_prior_value_forward_fill(self):
        """First bucket missing, no prior value -> zero-filled even with forward_fill."""
        raw = self._make_raw({
            self._START + 2 * self._STEP: 20.0,
            self._START + 3 * self._STEP: 30.0,
        })
        end = self._START + 3 * self._STEP

        aligned, gap = align_and_impute(raw, self._START, end, step_seconds=self._STEP,
                                         fill_policy="forward_fill")

        # First two buckets have no prior -> zero-filled
        assert aligned[self._START + 0 * self._STEP] == 0.0
        assert aligned[self._START + 1 * self._STEP] == 0.0
        assert aligned[self._START + 2 * self._STEP] == 20.0
        assert aligned[self._START + 3 * self._STEP] == 30.0
        assert gap == pytest.approx(2.0 / 4)


# ══════════════════════════════════════════════════════════════════════
# get_static_threshold_fallback  —  CPOA-63 fallback path
# ══════════════════════════════════════════════════════════════════════

class TestGetStaticThresholdFallback:
    """Fallback threshold lookup from DynamoDB policy table."""

    def test_found(self):
        """DynamoDB returns an Item with static_threshold -> return it."""
        _mock_policy_table.reset_mock()
        _mock_policy_table.get_item.return_value = {
            "Item": {"tenant_id": "t1", "service_name": "svc-a", "static_threshold": 42.0}
        }

        result = get_static_threshold_fallback("t1", "svc-a")

        assert result == 42.0
        _mock_policy_table.get_item.assert_called_once_with(
            Key={"tenant_id": "t1", "service_name": "svc-a"}
        )

    def test_not_found_default(self):
        """No Item in response -> default 85.0."""
        _mock_policy_table.reset_mock()
        _mock_policy_table.get_item.return_value = {}

        result = get_static_threshold_fallback("t1", "svc-a")

        assert result == 85.0

    def test_exception_default(self):
        """DynamoDB raises -> default 85.0, no crash."""
        _mock_policy_table.reset_mock()
        _mock_policy_table.get_item.side_effect = Exception("network error")

        result = get_static_threshold_fallback("t1", "svc-a")

        assert result == 85.0

    def test_missing_threshold_field_uses_default(self):
        """Item present but static_threshold key missing -> default 85.0."""
        _mock_policy_table.reset_mock()
        _mock_policy_table.get_item.return_value = {
            "Item": {"tenant_id": "t1", "service_name": "svc-a"}  # no static_threshold
        }

        result = get_static_threshold_fallback("t1", "svc-a")

        assert result == 85.0


# ══════════════════════════════════════════════════════════════════════
# save_audit_log  —  CPOA-68 | CDO-W12-027 (idempotency)
# ══════════════════════════════════════════════════════════════════════

class TestSaveAuditLog:
    """Audit log writes with ConditionExpression idempotency guard."""

    @staticmethod
    def _call_save(extra=None):
        kwargs = {
            "prediction_id": "pred-001",
            "tenant_id": "t1",
            "service_name": "svc-a",
            "decision": "KEEP_ALIVE",
            "prediction_source": "AI_ENGINE",
            "score": 0.75,
            "evidence_status": "complete_window",
            "anomaly": False,
            "severity": 0.2,
            "reasoning": "all clear",
        }
        if extra:
            kwargs.update(extra)
        save_audit_log(**kwargs)

    def test_successful_write(self):
        """Normal path: put_item succeeds without exception."""
        _mock_audit_table.reset_mock()
        _mock_audit_table.put_item.return_value = {}

        self._call_save()

        _mock_audit_table.put_item.assert_called_once()
        _, call_kwargs = _mock_audit_table.put_item.call_args
        item = call_kwargs["Item"]
        assert item["tenant_id"] == "t1"
        assert item["prediction_id"] == "pred-001"
        assert item["decision"] == "KEEP_ALIVE"
        assert item["score"] == Decimal("0.75")
        assert item["severity"] == Decimal("0.2")
        assert item["ai_status_code"] == Decimal("0")
        assert item["ai_latency_ms"] == Decimal("0")
        assert item["prediction_source"] == "AI_ENGINE"
        assert item["evidence_status"] == "complete_window"
        assert item["service_id"] == "svc-a"
        assert "expires_at_epoch" in item
        # ConditionExpression must enforce idempotency
        assert "attribute_not_exists(tenant_id)" in call_kwargs["ConditionExpression"]

    def test_idempotency_no_raise(self):
        """ConditionalCheckFailedException -> logged, not raised."""
        from botocore.exceptions import ClientError

        _mock_audit_table.reset_mock()
        _mock_audit_table.put_item.side_effect = ClientError(
            {"Error": {"Code": "ConditionalCheckFailedException", "Message": "Item exists"}},
            "PutItem",
        )

        # Should NOT raise
        self._call_save()

    def test_other_client_error_raises(self):
        """Non-ConditionalCheckFailed ClientError -> re-raised."""
        from botocore.exceptions import ClientError

        _mock_audit_table.reset_mock()
        _mock_audit_table.put_item.side_effect = ClientError(
            {"Error": {"Code": "ValidationException", "Message": "Bad request"}},
            "PutItem",
        )

        with pytest.raises(ClientError):
            self._call_save()

    def test_with_recommendation_fields(self):
        """Recommendation dict -> expanded into item fields."""
        _mock_audit_table.reset_mock()
        _mock_audit_table.put_item.reset_mock(side_effect=True)
        _mock_audit_table.put_item.return_value = {}

        self._call_save(extra={
            "recommendation": {
                "action_verb": "SCALE_UP",
                "target": "cpu",
                "from_to": "2->4",
                "confidence": 0.88,
                "evidence_link": "s3://logs/ev-001",
            }
        })

        _, kwargs = _mock_audit_table.put_item.call_args
        item = kwargs["Item"]
        assert item["recommendation_action"] == "SCALE_UP"
        assert item["recommendation_target"] == "cpu"
        assert item["recommendation_from_to"] == "2->4"
        assert item["recommendation_confidence"] == Decimal("0.88")
        assert item["recommendation_evidence"] == "s3://logs/ev-001"


# ══════════════════════════════════════════════════════════════════════
# process_job  —  AI-unreachable fallback paths
# ══════════════════════════════════════════════════════════════════════

class TestProcessJobFallback:
    """process_job must trigger STATIC_THRESHOLD_FALLBACK when AI is unreachable."""

    _BASE_JOB = {
        "correlation_id": "pred-fb-001",
        "tenant_id": "t1",
        "service_id": "svc-a",
        "lookback_window_minutes": 120,
    }

    def _mock_query(self, aligned_metrics=None, gap_ratio=0.0, start=1719705600, end=1719712800):
        """Patch query_amp_metrics to return controlled data."""
        return mock.patch(
            "prediction_worker.app.query_amp_metrics",
            return_value=(aligned_metrics or {}, gap_ratio, start, end),
        )

    def _mock_fallback(self, threshold=85.0):
        """Patch get_static_threshold_fallback."""
        return mock.patch(
            "prediction_worker.app.get_static_threshold_fallback",
            return_value=threshold,
        )

    def _mock_save(self):
        """Patch save_audit_log to a no-op."""
        return mock.patch("prediction_worker.app.save_audit_log")

    def _mock_sns(self):
        """Patch publish_sns_alert to a no-op."""
        return mock.patch("prediction_worker.app.publish_sns_alert")

    # ── AI unreachable: no AMP data ─────────────────────────────

    def test_message_id_used_when_correlation_missing(self):
        """Scheduler omits correlation_id; worker uses SQS MessageId for traceability."""
        job = {**self._BASE_JOB}
        job.pop("correlation_id")

        with self._mock_query(aligned_metrics={}, gap_ratio=1.0), \
             self._mock_fallback(85.0), \
             self._mock_save() as mock_save, \
             self._mock_sns():
            process_job(job, message_id="sqs-message-123")

        _, kwargs = mock_save.call_args
        assert kwargs["prediction_id"] == "sqs-message-123"

    def test_no_amp_data_triggers_fallback(self):
        """Empty aligned_metrics+high gap -> gap threshold branch, prediction_source fallback."""
        with self._mock_query(aligned_metrics={}, gap_ratio=1.0) as mock_q, \
             self._mock_fallback(85.0) as mock_fb, \
             self._mock_save() as mock_save, \
             self._mock_sns() as mock_sns:
            process_job(self._BASE_JOB)

        mock_q.assert_called_once()
        mock_fb.assert_called_once_with("t1", "svc-a")
        mock_save.assert_called_once()
        _, kwargs = mock_save.call_args
        assert kwargs["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
        # gap-threshold branch does NOT set prediction_status to fallback
        # ponytail: if desired, update process_job gap-threshold branch to also
        # set prediction_status="fallback" for consistency with AI-error paths.
        assert kwargs["decision"] == "SCALE_UP"    # 85.0 > 80.0
        assert kwargs["anomaly"] is True
        assert kwargs["severity"] == 0.85

    # ── AI unreachable: gap threshold exceeded ──────────────────

    def test_gap_exceeds_threshold_triggers_fallback(self):
        """max_gap_ratio >= 0.5 -> no AI call, fallback immediately."""
        aligned = {"cpu_usage_percent": {1719705600: 42.0}}
        with self._mock_query(aligned_metrics=aligned, gap_ratio=0.6) as mock_q, \
             self._mock_fallback(30.0) as mock_fb, \
             self._mock_save() as mock_save, \
             self._mock_sns() as mock_sns:
            process_job(self._BASE_JOB)

        mock_fb.assert_called_once_with("t1", "svc-a")
        _, kwargs = mock_save.call_args
        assert kwargs["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
        assert kwargs["decision"] == "KEEP_ALIVE"  # 30.0 <= 80.0
        assert kwargs["anomaly"] is False
        assert kwargs["severity"] == 0.3

    # ── AI reachable: complete AI path ─────────────────────────

    def test_ai_engine_success_records_contract_fields(self):
        """AI 200 response -> audit keeps correlation, status, recommendation contract."""
        start = 1719705600
        end = start + 120 * 60
        aligned = {"cpu_usage_percent": {start + i * 60: 42.0 for i in range(121)}}
        response = mock.MagicMock()
        response.status_code = 200
        response.json.return_value = {
            "anomaly": True,
            "severity": 0.9,
            "reasoning": "capacity drift detected",
            "audit_id": "audit-123",
            "recommendation": {
                "action_verb": "SCALE_UP",
                "target": "svc-a ECS Service",
                "from_to": "2 -> 3 tasks",
                "confidence": 0.91,
                "evidence_link": "https://dashboard.internal/metrics/svc-a",
            },
        }

        with self._mock_query(aligned_metrics=aligned, gap_ratio=0.0, start=start, end=end), \
             self._mock_save() as mock_save, \
             self._mock_sns(), \
             mock.patch("prediction_worker.app.requests.post", return_value=response):
            process_job(self._BASE_JOB)

        _, kwargs = mock_save.call_args
        assert kwargs["prediction_id"] == "pred-fb-001"
        assert kwargs["prediction_source"] == "AI_ENGINE"
        assert kwargs["evidence_status"] == "complete_window"
        assert kwargs["ai_status_code"] == 200
        assert kwargs["audit_id"] == "audit-123"
        assert kwargs["recommendation"]["action_verb"] == "SCALE_UP"
        assert {"action_verb", "target", "from_to", "confidence", "evidence_link"} <= set(kwargs["recommendation"])

    # ── AI unreachable: AI engine HTTP 500 error ────────────────

    def test_ai_engine_http_500_triggers_fallback(self):
        """AI engine returns non-200 -> fallback, fallback status."""
        _mock_response = mock.MagicMock()
        _mock_response.status_code = 500
        _mock_response.text = "Internal Server Error"

        aligned = {"cpu_usage_percent": {1719705600: 42.0}}
        with self._mock_query(aligned_metrics=aligned, gap_ratio=0.0), \
             self._mock_fallback(55.0) as mock_fb, \
             self._mock_save() as mock_save, \
             self._mock_sns() as mock_sns, \
             mock.patch("prediction_worker.app.requests.post", return_value=_mock_response):
            process_job(self._BASE_JOB)

        mock_fb.assert_called_once_with("t1", "svc-a")
        _, kwargs = mock_save.call_args
        assert kwargs["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
        assert kwargs["prediction_status"] == "fallback"
        assert kwargs["decision"] == "KEEP_ALIVE"  # 55.0 <= 80.0

    # ── AI unreachable: AI engine connection error ──────────────

    def test_ai_engine_connection_error_triggers_fallback(self):
        """AI engine raises ConnectionError -> fallback."""
        aligned = {"cpu_usage_percent": {1719705600: 42.0}}
        with self._mock_query(aligned_metrics=aligned, gap_ratio=0.0), \
             self._mock_fallback(95.0) as mock_fb, \
             self._mock_save() as mock_save, \
             self._mock_sns() as mock_sns, \
             mock.patch("prediction_worker.app.requests.post",
                        side_effect=ConnectionError("Connection refused")):
            process_job(self._BASE_JOB)

        mock_fb.assert_called_once_with("t1", "svc-a")
        _, kwargs = mock_save.call_args
        assert kwargs["prediction_source"] == "STATIC_THRESHOLD_FALLBACK"
        assert kwargs["prediction_status"] == "fallback"
        assert kwargs["decision"] == "SCALE_UP"   # 95.0 > 80.0
        assert kwargs["anomaly"] is True

    # ── Validation ──────────────────────────────────────────────

    def test_requires_tenant_id(self):
        """Missing tenant_id -> ValueError."""
        bad_job = {**self._BASE_JOB, "tenant_id": None}
        with pytest.raises(ValueError, match="tenant_id"):
            process_job(bad_job)

    def test_requires_service_id(self):
        """Missing service_id/service_name -> ValueError."""
        bad_job = {**self._BASE_JOB}
        del bad_job["service_id"]
        with pytest.raises(ValueError, match="service_id"):
            process_job(bad_job)

    def test_validates_lookback_120(self):
        """lookback_window_minutes != 120 -> ValueError."""
        bad_job = {**self._BASE_JOB, "lookback_window_minutes": 60}
        with pytest.raises(ValueError, match="120"):
            process_job(bad_job)

    def test_validates_lookback_type(self):
        """Non-numeric lookback_window_minutes -> ValueError."""
        bad_job = {**self._BASE_JOB, "lookback_window_minutes": "not-a-number"}
        with pytest.raises(ValueError, match="không đúng định dạng"):
            process_job(bad_job)
