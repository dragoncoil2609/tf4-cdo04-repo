"""Alarm, queue, and ECS routes — read-only CloudWatch, SQS, and ECS data.

GET /api/alarms  — list CloudWatch alarms
GET /api/queue   — list SQS queues with attributes
GET /api/ecs     — list ECS services
"""

from __future__ import annotations

from fastapi import APIRouter, Request

router = APIRouter()


@router.get("/api/alarms")
async def list_alarms(request: Request):
    """List CloudWatch alarms."""
    factory = request.app.state.aws_client_factory
    alarms = factory.list_alarms()
    return {"alarms": alarms, "count": len(alarms)}


@router.get("/api/queue")
async def list_queues(request: Request):
    """List SQS queues with attributes (read-only — never ReceiveMessage)."""
    factory = request.app.state.aws_client_factory
    outputs = request.app.state.terraform_discovery.discover()
    if not isinstance(outputs, dict):
        outputs = {}
    queue_urls = [
        url
        for url in (
            outputs.get("prediction_queue_url"),
            outputs.get("prediction_queue_dlq_url"),
        )
        if url
    ]
    queues = [factory.probe_sqs(url) for url in queue_urls] if queue_urls else factory.list_queues(prefix="tf4-cdo04")
    return {"queues": queues, "count": len(queues)}


@router.get("/api/ecs")
async def list_ecs(request: Request):
    """List ECS services with details."""
    factory = request.app.state.aws_client_factory
    outputs = request.app.state.terraform_discovery.discover()
    if not isinstance(outputs, dict):
        outputs = {}
    services = factory.list_ecs_services(outputs.get("ecs_cluster_name"))
    return {"ecs_services": services, "count": len(services)}
