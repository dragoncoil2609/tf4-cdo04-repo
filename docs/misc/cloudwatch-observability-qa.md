# CloudWatch Observability QA (Operational Scope)

## Scope

This QA covers current CloudWatch operational observability for `tf4-cdo04-repo/infra/terraform`.

Excluded by request:
- cost dashboard
- billing alarm
- AWS Budgets
- cost breaker Lambda

## Current state

| Area | Status | Notes |
|---|---|---|
| CloudWatch Logs | Present | ECS, API Gateway, Lambda, and AI audit log groups have retention. |
| CloudWatch Alarms | Present | ECS, ALB, SQS, DLQ, AI Engine, and Service Connect alarms exist. |
| Operational dashboard | Fixed | ALB widgets use target group ARN suffixes; ECS widgets use service-name variables. |
| SNS alerting | Fixed | Operational alert topic exists; pager-worthy alarms now include OK notifications. |
| ECS Container Insights | Present | Running task count, CPU, and memory alarms use ECS/ContainerInsights and AWS/ECS. |
| Custom AI metrics | Present | `Custom/AIEngine` metrics are used for AI latency, failures, fallback, audit, and AMP failure signals. |
| AMP / ADOT | Present | Telemetry API ADOT collector scrapes `/metrics` and remote-writes to AMP. |

## Findings

| Severity | Finding | Evidence | Impact | Recommendation |
|---|---|---|---|---|
| High | Operational dashboard uses stale ALB target group dimensions. | `modules/observability/main.tf` used `ledger-tg`, `payment-tg`, `kyc-tg`. Actual ALB target groups are telemetry API and AI Engine target groups. | ALB request, 5xx, and latency widgets can show no data. | Use full target group ARN suffix variables from compute outputs. |
| High | Operational dashboard uses stale ECS service dimensions. | `modules/observability/main.tf` used `ledger-service`, `payment-gateway`, `kyc-worker`. Actual services are Telemetry API, Prediction Worker, AI Engine. | ECS CPU/memory widget can show no data. | Use service name variables wired from compute/root module. |
| Medium | Duplicate DLQ alarm exists. | `main.tf` has `dlq_depth_alarm`; `alarms.tf` has `prediction_dlq_visible`. Both monitor same SQS DLQ metric and threshold. | One DLQ event can send duplicate alerts. | Keep `dlq_depth_alarm` because it has `ok_actions` and richer runbook metadata; remove duplicate. |
| Medium | Many pager-worthy alarms lack `ok_actions`. | Most alarms in `modules/observability/alarms.tf` only set `alarm_actions`. | Operators get failure notifications but not recovery notifications. | Add OK notifications to pager-worthy alarms; skip scale-in-only and warning-only alarms. |
| Low | AI memory warning alarm has no action. | `ai_engine_memory` has no `alarm_actions`. | Warning can be invisible outside dashboard/console. | Keep as-is for this fix because it is explicitly marked warning-only. Revisit when warning policy is defined. |

## Fixes applied

- Operational dashboard ALB widgets now use target group ARN suffixes instead of stale target group names.
- Operational dashboard ECS widget now uses real ECS service-name variables.
- Duplicate `prediction_dlq_visible` alarm removed.
- OK notifications added to pager-worthy operational alarms.
- CPOA-102 CPU/memory alarms routed to `budget_alert` now also send recovery notifications to the same topic.

## Remaining best-practice gaps

These are intentionally not fixed in this pass.

| Gap | Why it matters | Suggested next step |
|---|---|---|
| No composite alarms | Many related alarms can fire together and create noise. | Add composite alarms for Telemetry API, Prediction Pipeline, and AI Engine health. |
| No SLO / burn-rate alarms | Static threshold alarms do not track error-budget burn. | Add CloudWatch Application Signals SLOs or equivalent metric-math burn-rate alarms. |
| No anomaly detection | Static thresholds can age poorly as traffic changes. | Add anomaly detection for latency and request-volume metrics after baseline data exists. |
| No Contributor Insights | High-cardinality troubleshooting is harder from metrics alone. | Add Contributor Insights rules for structured logs: endpoint, error type, tenant/customer if present. |
| Limited dashboard drilldown | Dashboard lacks API Gateway, target health, Lambda self-monitoring, and alarm-state widgets. | Add operational widgets after current dimensions are fixed and validated. |

## Verification checklist

Run from `tf4-cdo04-repo/infra/terraform`:

```bash
terraform fmt -recursive -check -diff
terraform validate
terraform plan -target=module.observability
```

Focused checks:

```bash
rg "ledger|payment-gateway|payment-tg|kyc" modules/observability/main.tf
rg "prediction_dlq_visible" modules/observability/alarms.tf
rg "ai_engine_target_group_arn_suffix" .
```

Expected:
- no stale dashboard names in `modules/observability/main.tf`
- no `prediction_dlq_visible` resource
- `ai_engine_target_group_arn_suffix` defined and wired
- Terraform validate passes
