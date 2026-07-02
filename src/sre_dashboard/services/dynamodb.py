"""DynamoDB service — audit log reads and policy CRUD (read + conditional update)."""

from __future__ import annotations

import logging
from datetime import datetime
from decimal import Decimal
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger("sre_dashboard.dynamodb")


class DynamoDbService:
    """Read and write operations against CDO DynamoDB tables.

    Audit logs: read-only queries (scan with optional filters).
    Policies: read and conditional update (never deletes).
    """

    def __init__(
        self,
        audit_table_name: str,
        policy_table_name: str,
        region: str,
        profile: str | None = None,
    ) -> None:
        session_kwargs: dict[str, Any] = {"region_name": region}
        if profile:
            session_kwargs["profile_name"] = profile
        self._session = boto3.Session(**session_kwargs)
        self._dynamodb = self._session.resource("dynamodb")
        self._audit_table = self._dynamodb.Table(audit_table_name)
        self._policy_table = self._dynamodb.Table(policy_table_name)

    # ── Tenants & Services ───────────────────────────────────────

    def list_tenants(self) -> list[str]:
        """Scan audit table for distinct tenant_id values."""
        try:
            response = self._audit_table.scan(
                ProjectionExpression="tenant_id",
                Limit=1000,
            )
            tenants = set()
            for item in response.get("Items", []):
                tid = item.get("tenant_id")
                if tid:
                    tenants.add(tid)
            # Also scan policy table for tenants
            pol_response = self._policy_table.scan(
                ProjectionExpression="tenant_id",
                Limit=1000,
            )
            for item in pol_response.get("Items", []):
                tid = item.get("tenant_id")
                if tid:
                    tenants.add(tid)
            return sorted(tenants)
        except Exception as exc:
            logger.warning("list_tenants failed: %s", exc)
            return []

    def list_services(self, tenant_id: str) -> list[str]:
        """Query policy table for service names owned by a tenant."""
        try:
            response = self._policy_table.query(
                KeyConditionExpression=Key("tenant_id").eq(tenant_id),
                ProjectionExpression="service_name",
                Limit=1000,
            )
            services = set()
            for item in response.get("Items", []):
                svc = item.get("service_name") or item.get("service_id")
                if svc:
                    services.add(svc)
            return sorted(services)
        except Exception as exc:
            logger.warning("list_services failed for tenant %s: %s", tenant_id, exc)
            return []

    # ── Overview (aggregated state per tenant) ───────────────────

    def get_overview(self, tenant_id: str) -> dict[str, Any]:
        """Get a summary overview for a tenant.

        Returns service counts, recent alerts, and policy stats.
        Partial failures return section-level errors.
        """
        overview: dict[str, Any] = {
            "tenant_id": tenant_id,
            "services": [],
            "recent_alarms": [],
            "policies": [],
            "errors": [],
        }

        # Services
        try:
            response = self._audit_table.scan(
                FilterExpression="tenant_id = :tid",
                ExpressionAttributeValues={":tid": tenant_id},
                ProjectionExpression="service_name, #ts, decision, score, severity, anomaly",
                ExpressionAttributeNames={"#ts": "timestamp"},
                Limit=500,
            )
            svc_map: dict[str, dict] = {}
            for item in response.get("Items", []):
                svc_name = item.get("service_name") or item.get("service_id") or "unknown"
                if svc_name not in svc_map:
                    svc_map[svc_name] = {
                        "service_name": svc_name,
                        "latest_decision": "UNKNOWN",
                        "latest_score": 0.0,
                        "anomaly": False,
                        "severity": 0.0,
                    }
                # Keep the most recent entry (entries come unsorted; take latest)
                svc_map[svc_name]["latest_decision"] = item.get("decision", svc_map[svc_name]["latest_decision"])
                svc_map[svc_name]["latest_score"] = float(item.get("score", 0))
                svc_map[svc_name]["anomaly"] = item.get("anomaly", False) or svc_map[svc_name]["anomaly"]
                svc_map[svc_name]["severity"] = max(
                    float(item.get("severity", 0)), svc_map[svc_name]["severity"]
                )
            overview["services"] = list(svc_map.values())
        except Exception as exc:
            overview["errors"].append(f"services: {exc}")

        # Policies
        try:
            pol_response = self._policy_table.scan(
                FilterExpression="tenant_id = :tid",
                ExpressionAttributeValues={":tid": tenant_id},
                Limit=100,
            )
            for item in pol_response.get("Items", []):
                overview["policies"].append({
                    "tenant_id": item.get("tenant_id"),
                    "service_name": item.get("service_name"),
                    "static_threshold": float(item.get("static_threshold", 85)),
                    "enabled": item.get("enabled", True),
                })
        except Exception as exc:
            overview["errors"].append(f"policies: {exc}")

        return overview

    # ── Audit Logs ───────────────────────────────────────────────

    def query_audit_logs(
        self,
        tenant_id: str,
        service_id: str | None = None,
        limit: int = 50,
    ) -> list[dict[str, Any]]:
        """Query audit logs for a tenant, optionally filtered by service.

        Uses the audit table tenant_id partition key, then filters service in-process
        because no tenant/service GSI exists.
        """
        try:
            response = self._audit_table.query(
                KeyConditionExpression=Key("tenant_id").eq(tenant_id),
                ScanIndexForward=False,
                Limit=limit,
            )
            items = response.get("Items", [])
            if service_id:
                items = [
                    item for item in items
                    if (item.get("service_name") or item.get("service_id")) == service_id
                ]
            result = []
            for item in items[:limit]:
                result.append({
                    "tenant_id": item.get("tenant_id"),
                    "service_name": item.get("service_name") or item.get("service_id"),
                    "prediction_id": item.get("prediction_id"),
                    "decision": item.get("decision"),
                    "prediction_source": item.get("prediction_source"),
                    "score": float(item.get("score", 0)),
                    "anomaly": item.get("anomaly", False),
                    "severity": float(item.get("severity", 0)),
                    "reasoning": item.get("reasoning", ""),
                    "timestamp": item.get("timestamp"),
                    "service_time": item.get("service_time"),
                })
            return result
        except Exception as exc:
            logger.warning("query_audit_logs failed: %s", exc)
            return []

    # ── Policies ─────────────────────────────────────────────────

    def list_policies(self, tenant_id: str | None = None) -> list[dict[str, Any]]:
        """List all policies, optionally filtered by tenant."""
        try:
            kwargs: dict[str, Any] = {"Limit": 100}
            if tenant_id:
                kwargs["FilterExpression"] = "tenant_id = :tid"
                kwargs["ExpressionAttributeValues"] = {":tid": tenant_id}

            response = self._policy_table.scan(**kwargs)
            policies = []
            for item in response.get("Items", []):
                policies.append({
                    "tenant_id": item.get("tenant_id"),
                    "service_name": item.get("service_name"),
                    "static_threshold": float(item.get("static_threshold", 85)),
                    "enabled": bool(item.get("enabled", True)),
                })
            return policies
        except Exception as exc:
            logger.warning("list_policies failed: %s", exc)
            return []

    def update_policy(
        self,
        tenant_id: str,
        service_name: str,
        static_threshold: float,
        enabled: bool | None = None,
        expected_old_value: float | None = None,
    ) -> dict[str, Any]:
        """Update a policy threshold with conditional write.

        Validates that threshold is 0-100 before updating.
        If expected_old_value is provided, the update only succeeds if the
        current static_threshold matches (optimistic concurrency).
        """
        if not (0 <= static_threshold <= 100):
            return {
                "status": "error",
                "detail": f"static_threshold must be 0-100 (got {static_threshold})",
            }

        try:
            update_expr = "SET static_threshold = :val"
            expr_attr_values: dict[str, Any] = {":val": Decimal(str(static_threshold))}
            condition_expr: str | None = None

            if enabled is not None:
                update_expr += ", #en = :en"
                expr_attr_values[":en"] = enabled

            condition_expr = "attribute_exists(tenant_id) AND attribute_exists(service_name)"
            if expected_old_value is not None:
                condition_expr += " AND static_threshold = :expected"
                expr_attr_values[":expected"] = Decimal(str(expected_old_value))

            update_kwargs: dict[str, Any] = {
                "Key": {"tenant_id": tenant_id, "service_name": service_name},
                "UpdateExpression": update_expr,
                "ExpressionAttributeValues": expr_attr_values,
                "ReturnValues": "ALL_NEW",
            }
            if enabled is not None:
                update_kwargs["ExpressionAttributeNames"] = {"#en": "enabled"}
            if condition_expr:
                update_kwargs["ConditionExpression"] = condition_expr

            response = self._policy_table.update_item(**update_kwargs)
            attrs = response.get("Attributes", {})
            return {
                "status": "ok",
                "tenant_id": attrs.get("tenant_id", tenant_id),
                "service_name": attrs.get("service_name", service_name),
                "static_threshold": float(attrs.get("static_threshold", static_threshold)),
                "enabled": bool(attrs.get("enabled", True)),
            }
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            if code == "ConditionalCheckFailedException":
                return {
                    "status": "conflict",
                    "detail": "Conditional check failed: expected_old_value does not match current value",
                }
            return {"status": "error", "detail": str(exc)}
        except Exception as exc:
            logger.warning("update_policy failed: %s", exc)
            return {"status": "error", "detail": str(exc)}
