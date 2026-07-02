"""AWS client factory — creates boto3 clients from a configured Session.

Never returns credentials to the caller.
"""

from __future__ import annotations

import logging
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger("sre_dashboard.aws_client")


class AwsClientFactory:
    """Creates and caches boto3 clients from a shared Session.

    The session is created once from the caller's SSO profile (or default
    credential chain) and never exposed to callers.
    """

    def __init__(self, region: str, profile: str | None = None) -> None:
        self._region = region
        self._profile = profile
        session_kwargs: dict[str, Any] = {"region_name": region}
        if profile:
            session_kwargs["profile_name"] = profile
        self._session = boto3.Session(**session_kwargs)
        self._clients: dict[str, Any] = {}

    def _client(self, service: str):
        if service not in self._clients:
            self._clients[service] = self._session.client(service)
        return self._clients[service]

    # ── Permission probes (read-only) ────────────────────────────

    def probe_sts(self) -> dict:
        """Call STS GetCallerIdentity to verify credentials are valid."""
        try:
            sts = self._client("sts")
            identity = sts.get_caller_identity()
            return {
                "status": "ok",
                "account_id": identity.get("Account"),
                "arn": identity.get("Arn"),
            }
        except Exception as exc:
            logger.warning("STS probe failed: %s", exc)
            return {"status": "error", "detail": str(exc)}

    def probe_amp(self) -> dict:
        """List AMP workspaces — succeeds if caller can read AMP."""
        try:
            amp = self._client("amp")
            workspaces = amp.list_workspaces(maxResults=1)
            return {"status": "ok", "workspace_count": len(workspaces.get("workspaces", []))}
        except Exception as exc:
            logger.warning("AMP probe failed: %s", exc)
            return {"status": "error", "detail": str(exc)}

    def probe_dynamodb(self, table_name: str) -> dict:
        """Describe a DynamoDB table to verify read access."""
        try:
            ddb = self._client("dynamodb")
            ddb.describe_table(TableName=table_name)
            return {"status": "ok", "table": table_name}
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            if code == "AccessDeniedException":
                return {"status": "denied", "detail": code}
            return {"status": "error", "detail": str(exc)}
        except Exception as exc:
            return {"status": "error", "detail": str(exc)}

    def probe_sqs(self, queue_url: str) -> dict:
        """Call GetQueueAttributes (read-only). Never calls ReceiveMessage."""
        try:
            sqs = self._client("sqs")
            response = sqs.get_queue_attributes(
                QueueUrl=queue_url,
                AttributeNames=["All"],
            )
            attrs = response.get("Attributes", {})
            return {
                "status": "ok",
                "queue_url": queue_url,
                "approximate_number_of_messages": int(attrs.get("ApproximateNumberOfMessages", 0)),
                "approximate_number_of_messages_not_visible": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
            }
        except Exception as exc:
            logger.warning("SQS probe failed: %s", exc)
            return {"status": "error", "detail": str(exc)}

    def probe_cloudwatch(self) -> dict:
        """Describe CloudWatch alarms to verify read access."""
        try:
            cw = self._client("cloudwatch")
            alarms = cw.describe_alarms(MaxRecords=1)
            return {"status": "ok", "alarm_count": len(alarms.get("MetricAlarms", []))}
        except Exception as exc:
            return {"status": "error", "detail": str(exc)}

    def probe_ecs(self, cluster: str | None = None) -> dict:
        """Describe ECS services to verify read access."""
        try:
            ecs = self._client("ecs")
            kwargs: dict[str, Any] = {"maxResults": 5}
            if cluster:
                kwargs["cluster"] = cluster
            services = ecs.list_services(**kwargs)
            return {"status": "ok", "service_arns": services.get("serviceArns", [])}
        except Exception as exc:
            return {"status": "error", "detail": str(exc)}

    # ── Service-specific operations ──────────────────────────────

    def list_queues(self, prefix: str = "") -> list[dict]:
        """List SQS queues and return basic attributes (read-only)."""
        try:
            sqs = self._client("sqs")
            if prefix:
                queues = sqs.list_queues(QueueNamePrefix=prefix)
            else:
                queues = sqs.list_queues()
            queue_urls = queues.get("QueueUrls", [])
            results = []
            for url in queue_urls:
                attrs = sqs.get_queue_attributes(
                    QueueUrl=url, AttributeNames=["All"]
                ).get("Attributes", {})
                results.append({
                    "queue_url": url,
                    "queue_name": url.split("/")[-1],
                    "approximate_number_of_messages": int(attrs.get("ApproximateNumberOfMessages", 0)),
                    "approximate_number_of_messages_not_visible": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
                })
            return results
        except Exception as exc:
            logger.warning("list_queues failed: %s", exc)
            return []

    def list_ecs_services(self, cluster: str | None = None) -> list[dict]:
        """List ECS services with details (read-only)."""
        try:
            ecs = self._client("ecs")
            kwargs: dict[str, Any] = {}
            if cluster:
                kwargs["cluster"] = cluster
            paginator = ecs.get_paginator("list_services")
            all_arns: list[str] = []
            for page in paginator.paginate(**kwargs):
                all_arns.extend(page.get("serviceArns", []))
            if not all_arns:
                return []
            cluster_name = cluster or all_arns[0].split(":")[5].split("/")[0]
            details = ecs.describe_services(
                cluster=cluster_name, services=all_arns
            )
            services_data = []
            for svc in details.get("services", []):
                services_data.append({
                    "service_name": svc.get("serviceName"),
                    "status": svc.get("status"),
                    "desired_count": svc.get("desiredCount"),
                    "running_count": svc.get("runningCount"),
                    "pending_count": svc.get("pendingCount"),
                    "launch_type": svc.get("launchType"),
                    "task_definition": svc.get("taskDefinition"),
                    "cluster_arn": svc.get("clusterArn"),
                })
            return services_data
        except Exception as exc:
            logger.warning("list_ecs_services failed: %s", exc)
            return []

    def list_alarms(self) -> list[dict]:
        """List CloudWatch alarms (read-only)."""
        try:
            cw = self._client("cloudwatch")
            paginator = cw.get_paginator("describe_alarms")
            alarms = []
            for page in paginator.paginate():
                for alarm in page.get("MetricAlarms", []):
                    alarms.append({
                        "alarm_name": alarm.get("AlarmName"),
                        "state_value": alarm.get("StateValue"),
                        "state_reason": alarm.get("StateReason"),
                        "metric_name": alarm.get("MetricName"),
                        "namespace": alarm.get("Namespace"),
                        "threshold": alarm.get("Threshold"),
                        "comparison_operator": alarm.get("ComparisonOperator"),
                    })
            return alarms
        except Exception as exc:
            logger.warning("list_alarms failed: %s", exc)
            return []

    def describe_alarms(self) -> list[dict]:
        """Alias for list_alarms."""
        return self.list_alarms()
