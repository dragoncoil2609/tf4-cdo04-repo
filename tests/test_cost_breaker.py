from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from unittest.mock import MagicMock, patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "src" / "lambda" / "cost_breaker.py"


def load_module():
    spec = importlib.util.spec_from_file_location("cost_breaker", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def event_for(message: str) -> dict:
    return {"Records": [{"Sns": {"Message": message}}]}


def budget_event(threshold: int) -> dict:
    return event_for(json.dumps({"thresholdInfo": {"thresholdValue": threshold}}))


def env(dry_run: str = "false") -> dict:
    return {
        "CLUSTER_NAME": "tf4-cdo04-sandbox-cluster",
        "SERVICE_NAME": "tf4-cdo04-sandbox-ai-engine",
        "WORKER_SERVICE_NAME": "tf4-cdo04-sandbox-prediction-worker",
        "SNS_TOPIC_ARN": "arn:aws:sns:us-east-1:123456789012:budget-alert",
        "DRY_RUN": dry_run,
    }


def mock_clients():
    ecs = MagicMock()
    sns = MagicMock()

    def client(name):
        return {"ecs": ecs, "sns": sns}[name]

    return ecs, sns, client


def test_50_percent_threshold_skips_breaker():
    module = load_module()
    with patch.dict(module.os.environ, env(), clear=True), patch.object(module.boto3, "client") as client:
        response = module.handler(budget_event(50), None)

    assert response["statusCode"] == 200
    client.assert_not_called()


def test_80_percent_threshold_skips_breaker():
    module = load_module()
    with patch.dict(module.os.environ, env(), clear=True), patch.object(module.boto3, "client") as client:
        response = module.handler(budget_event(80), None)

    assert response["statusCode"] == 200
    client.assert_not_called()


def test_100_percent_threshold_scales_only_ai_and_worker():
    module = load_module()
    ecs, sns, client = mock_clients()
    with patch.dict(module.os.environ, env(), clear=True), patch.object(module.boto3, "client", side_effect=client):
        response = module.handler(budget_event(100), None)

    assert response["statusCode"] == 200
    ecs.update_service.assert_any_call(
        cluster="tf4-cdo04-sandbox-cluster",
        service="tf4-cdo04-sandbox-ai-engine",
        desiredCount=0,
    )
    ecs.update_service.assert_any_call(
        cluster="tf4-cdo04-sandbox-cluster",
        service="tf4-cdo04-sandbox-prediction-worker",
        desiredCount=0,
    )
    assert ecs.update_service.call_count == 2
    assert "telemetry" not in str(ecs.update_service.call_args_list)
    sns.publish.assert_called_once()


def test_malformed_message_with_threshold_info_does_not_activate_without_100_percent():
    module = load_module()
    message = "malformed thresholdInfo payload for 80 percent budget"
    with patch.dict(module.os.environ, env(), clear=True), patch.object(module.boto3, "client") as client:
        response = module.handler(event_for(message), None)

    assert response["statusCode"] == 200
    client.assert_not_called()


def test_malformed_message_with_explicit_100_percent_activates_fallback():
    module = load_module()
    ecs, sns, client = mock_clients()
    with patch.dict(module.os.environ, env(), clear=True), patch.object(module.boto3, "client", side_effect=client):
        response = module.handler(event_for("Budget threshold breached at 100%"), None)

    assert response["statusCode"] == 200
    assert ecs.update_service.call_count == 2
    sns.publish.assert_called_once()


def test_dry_run_does_not_scale_or_publish():
    module = load_module()
    ecs, sns, client = mock_clients()
    with patch.dict(module.os.environ, env(dry_run="true"), clear=True), patch.object(module.boto3, "client", side_effect=client):
        response = module.handler(budget_event(100), None)

    assert response["statusCode"] == 200
    ecs.update_service.assert_not_called()
    sns.publish.assert_not_called()


def test_missing_cluster_skips_destructive_action():
    module = load_module()
    bad_env = env()
    bad_env["CLUSTER_NAME"] = ""
    with patch.dict(module.os.environ, bad_env, clear=True), patch.object(module.boto3, "client") as client:
        response = module.handler(budget_event(100), None)

    assert response["statusCode"] == 500
    client.assert_not_called()
