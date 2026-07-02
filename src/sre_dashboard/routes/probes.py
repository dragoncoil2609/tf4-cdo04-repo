"""Permission probes route.

GET /api/probes — run all AWS permission probes and return section-level results.
"""

from __future__ import annotations

from fastapi import APIRouter, Request

router = APIRouter()


@router.get("/api/probes")
async def probes(request: Request):
    """Run all AWS permission probes and return results.

    Each probe is independent; partial failures produce section-level errors
    rather than failing the whole request.
    """
    factory = request.app.state.aws_client_factory
    settings = request.app.state.settings
    tf = request.app.state.terraform_discovery
    outputs = tf.discover()

    # Discover resource names from terraform outputs
    queue_url = outputs.get("prediction_queue_url") or outputs.get("sqs_queue_url") or outputs.get("queue_url", "")
    policy_table = outputs.get("policy_table_name") or settings.policy_table_name
    audit_table = outputs.get("audit_table_name") or settings.audit_table_name
    ecs_cluster = outputs.get("ecs_cluster_name")

    return {
        "sts": factory.probe_sts(),
        "amp": factory.probe_amp(),
        "dynamodb_audit": factory.probe_dynamodb(audit_table),
        "dynamodb_policies": factory.probe_dynamodb(policy_table),
        "sqs": factory.probe_sqs(queue_url) if queue_url else {"status": "skipped", "detail": "No SQS queue URL configured"},
        "cloudwatch": factory.probe_cloudwatch(),
        "ecs": factory.probe_ecs(ecs_cluster),
    }
