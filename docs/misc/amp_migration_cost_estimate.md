# AMP Migration Cost Estimate - CDO-04

<!-- Doc owner: CDO-04
     Status: Accepted decision support
     Date updated: 2026-06-26
     Scope: Accepted migration support from ap-southeast-1 + Timestream for InfluxDB to us-east-1 + Amazon Managed Service for Prometheus -->

## 1. Executive summary

> **Accepted-docs note (2026-06-26):** Main docs now use public ingest ALB plus ECS Service Connect for private Worker → AI routing. That makes the accepted physical design about **$158.16/month** before buffer and **$189.79/month** with 20% buffer, assuming Service Connect proxy headroom does not force Fargate task upsize. Current source of truth is `02_infra_design.md`, `05_cost_analysis.md`, and ADR-011.


This file estimates the impact of changing the current CDO-04 infrastructure decision from:

```text
Region: ap-southeast-1 / Singapore
TSDB  : Amazon Timestream for InfluxDB db.influx.medium Single-AZ
```

to:

```text
Region: us-east-1 / US East (N. Virginia)
TSDB  : Amazon Managed Service for Prometheus (AMP)
```

The estimate uses the current CDO docs as the functional design, especially:

- `docs/02_infra_design.md`
- `docs/03_security_design.md`
- `docs/04_deployment_design.md`
- `docs/05_cost_analysis.md`
- `docs/08_adrs.md`
- `TF4-AIO-03-foresight-lens-final/contracts/*`

### Final answer

| Question | Answer |
|---|---|
| Does moving to `us-east-1` + AMP reduce cost? | **Yes.** The largest saving is replacing fixed `db.influx.medium` InfluxDB cost (~$103.66/month) with AMP usage-based pricing that is effectively near-zero for the current demo volume. |
| Estimated full-month always-on cost after migration | **~$158.16/month** using the same doc-priced one-ALB design and x86 Fargate. |
| Estimated full-month cost with 20% ops buffer | **~$189.79/month**, still under the $200/month target. |
| Can it still meet AI lead-time requirement ≥15 minutes? | **Yes, if all CDO runtime components and AI Engine are co-located in `us-east-1` and the Worker still keeps 1-minute telemetry, 5-minute prediction cadence, and a complete 120-minute signal window.** |
| Does it require contract/doc changes? | **CDO docs/ADRs yes; frozen AI contracts no.** Contract review found the AI deployment contract already defaults `AWS_REGION` to `us-east-1` and treats the engine as region-agnostic by CDO deployment region. The API schema/auth/SLA do not change. |
| Main engineering risk | AMP is not InfluxDB. It changes the telemetry data model and query layer from InfluxDB org/bucket/measurement/tags/fields + Flux to Prometheus metrics/labels + PromQL. |

Recommendation:

> If budget fit is now the top priority, `us-east-1` + AMP is a strong alternative because it brings the full always-on estimate back under $200/month. However, it should be recorded as a new CDO ADR because it changes the CDO deployment region, TSDB product, query language, evidence query format, and IAM model. The frozen AI API/deployment contracts remain compatible.

---

## 2. Source-of-truth design before migration

Current CDO design from `02_infra_design.md` and `05_cost_analysis.md`:

| Area | Current decision |
|---|---|
| Region | `ap-southeast-1` / Singapore |
| Compute | ECS Fargate for Telemetry API, Prediction Worker, and AI Engine |
| Runtime task count | 5 tasks total: Telemetry API 2, Prediction Worker 1, AI Engine 2 |
| Task size | 0.5 vCPU / 1GB each |
| Ingest path | Public ALB HTTPS `/v1/ingest` |
| AI path | Worker -> ECS Service Connect service name -> AI Engine `/v1/predict` |
| Prediction cadence | Every 5 minutes |
| Telemetry frequency | Every 1 minute |
| AI lookback window | Exactly/at least 120 minutes of recent telemetry |
| Current TSDB | Amazon Timestream for InfluxDB `db.influx.medium` Single-AZ |
| Audit store | DynamoDB audit + service policy tables |
| Orchestration | EventBridge Scheduler -> SQS -> Prediction Worker, with DLQ |
| Evidence | TSDB metric evidence + CloudWatch dashboard/log evidence + DynamoDB audit decision evidence + S3 snapshots |
| Current full-month cost | ~$296.04/month |

Current cost driver:

```text
Timestream for InfluxDB db.influx.medium Single-AZ
= $0.142/hour × 730h
= ~$103.66/month
```

That fixed instance-hour cost is why the current full-month estimate no longer fits the $200/month target.

---

## 3. What changes if migrating to `us-east-1` + AMP

### 3.1 Region-level changes

All regional resources would move from `ap-southeast-1` to `us-east-1`:

| Resource class | Impact |
|---|---|
| VPC/subnets/NAT/endpoints/security groups | Recreated in `us-east-1`; CIDR/topology can stay logically the same. |
| ECS cluster/services/task definitions | Recreated in `us-east-1`; image URIs must point to ECR in `us-east-1` or use replicated images. |
| ALB/target groups/listeners/ACM | Recreated in `us-east-1`; ACM certificates are regional for ALB use. |
| SQS/DLQ/EventBridge Scheduler | Recreated in `us-east-1`; queue ARNs/URLs and scheduler target ARNs change. |
| DynamoDB tables | Recreated or migrated; audit history from Singapore does not automatically move. |
| S3 buckets | Bucket names are globally unique; data migration/lifecycle policy must be planned if evidence/baseline data already exists. |
| Secrets Manager/KMS | Recreated in `us-east-1`; secret ARNs and KMS key ARNs change. |
| CloudWatch logs/alarms/dashboard | Recreated in `us-east-1`; historical logs/metrics stay in old region unless exported. |
| AWS Budgets | Budgeting is account-level, but cost filters/tags may need update. |

AWS Knowledge regional availability check confirms `us-east-1` supports:

- Amazon Managed Service for Prometheus
- Amazon ECS
- Elastic Load Balancing
- Amazon VPC

### 3.2 TSDB/data-model changes

This is the largest design change.

| Current Timestream for InfluxDB model | New AMP model |
|---|---|
| InfluxDB org `tf4-cdo04` | AMP workspace |
| InfluxDB bucket `telemetry` | Prometheus remote-write endpoint |
| Measurement `service_metrics` | Prometheus metric names, e.g. `api_latency_ms`, `cpu_usage_percent` |
| Tags: `tenant_id`, `service_id`, `metric_type`, `env`, `region` | Labels: `tenant_id`, `service_id`, `env`, `region`, plus signal-specific labels |
| Fields: `value`, optional `unit`/`sample_count` | Sample value is the Prometheus datapoint value; units are encoded in metric naming/conventions |
| Query language: Flux | Query language: PromQL |
| App auth: InfluxDB tokens in Secrets Manager | AWS IAM/SigV4 for AMP APIs/remote write |

Required application/platform changes:

1. **Telemetry API write path**
   - Current: build InfluxDB points and write to Timestream for InfluxDB.
   - New: expose/emit Prometheus-compatible metrics and remote-write samples to AMP, or run an ADOT collector sidecar that scrapes app `/metrics` endpoints and remote-writes to AMP.

2. **Prediction Worker query path**
   - Current: Flux query against InfluxDB bucket.
   - New: PromQL query against AMP workspace.
   - Runtime queries must still filter by `tenant_id`, `service_id`, metric names, and exact time window.

3. **Evidence references**
   - Current: Flux query reference / InfluxDB evidence.
   - New: PromQL query reference / AMP workspace query / Grafana panel link.

4. **IAM/secrets**
   - Remove InfluxDB write/read/admin token secrets from the app config.
   - Add IAM permissions for AMP remote write/query.
   - Keep Secrets Manager for tenant ingest token, AI endpoint config, webhook secret, and other app config.

5. **Retention**
   - Current target: 90 days.
   - AMP stores metrics for 150 days by default and can be configured up to 1095 days. This exceeds the current 90-day telemetry retention requirement.

### 3.3 Network changes

The basic network decision can remain the same:

```text
1 zonal NAT Gateway + S3/DynamoDB Gateway Endpoints
```

Reason:

- ECS tasks still need outbound access to AWS APIs such as ECR, CloudWatch Logs, Secrets Manager, KMS, SQS, SNS, and now AMP.
- S3 and DynamoDB should still use Gateway Endpoints at $0/hour.
- AMP supports PrivateLink, so a private-only hardening path exists, but adding interface endpoints increases fixed cost.

For the current cost-optimized MVP, AMP traffic can use the same NAT path as the old AWS API traffic. If security-first private-only access is required later, add an interface endpoint for AMP/APS plus the other runtime endpoints.

---

## 4. AWS pricing evidence used

### 4.1 AMP pricing in `us-east-1`

AWS Pricing API returned the following for `AmazonPrometheus` in `us-east-1`:

| AMP item | Price |
|---|---:|
| Metric samples ingested | First 40M samples/month: **$0.00**; then **$0.90 per 10M samples** up to 2B samples |
| Metric storage | First 10GB/month: **$0.00**; then **$0.03 per GB-month** |
| Query samples processed | **$0.10 per 1B query samples processed** |
| Managed collector hours | **$0.04 per collector-hour** if using AMP managed collector |

AWS docs also state:

- AMP is pay-as-you-go based on metrics ingested, queried, stored, and collected.
- There is no Data Transfer IN charge for AMP.
- Metrics are retained for 150 days by default and can be configured up to 1095 days.
- Remote write endpoint: `/workspaces/{workspaceId}/api/v1/remote_write`.
- RemoteWrite documented ingestion rate: **70,000 samples/second** with burst size **1,000,000 samples**.
- Service quota page lists ingestion rate per workspace default around **1,666,666 samples/second**, active series per workspace **50M**, and query APIs/limits that are far above the demo path.

### 4.2 Other `us-east-1` unit prices from AWS Pricing API

| Service | `us-east-1` unit price |
|---|---:|
| ECS Fargate x86 vCPU | **$0.04048/vCPU-hour** |
| ECS Fargate x86 memory | **$0.004445/GB-hour** |
| ECS Fargate ARM vCPU | **$0.03238/vCPU-hour** |
| ECS Fargate ARM memory | **$0.00356/GB-hour** |
| Application Load Balancer | **$0.0225/ALB-hour** |
| ALB LCU | **$0.008/LCU-hour** |
| NAT Gateway hourly | **$0.045/hour** |
| NAT Gateway data processing | **$0.045/GB** |
| Interface VPC endpoint, from existing VPCE note | **$0.010/endpoint-AZ-hour + $0.010/GB** |

---

## 5. AMP volume model for CDO-04

### 5.1 Demo/current decision volume

Current required AI signals from the AI telemetry contract:

```text
cpu_usage_percent
memory_usage_percent
active_connections
db_connection_pool_pct
queue_depth
cache_hit_rate_pct
api_latency_ms
```

Current CDO volume from `05_cost_analysis.md`:

```text
7 metrics × 60 minutes × 24 hours × 30 days = 302,400 metric points/service/month
3 services = 907,200 metric points/month
```

Prediction cycles:

```text
3 services × 12 cycles/hour × 24 hours × 30 days = 25,920 prediction cycles/month
```

Approximate AMP query samples for Worker hot path:

```text
Each prediction query ~= 7 metrics × 120 one-minute samples = 840 query samples
25,920 cycles × 840 = 21,772,800 query samples/month
```

### 5.2 AMP monthly cost for current demo scope

| AMP dimension | Usage estimate | Pricing | Monthly cost |
|---|---:|---:|---:|
| Ingested samples | 907,200 samples/month | Under 40M free tier | **$0.00** |
| Storage | Far below 10GB/month at demo scope | Under 10GB free tier | **$0.00** |
| Query samples processed | ~21.8M/month for Worker hot path | Under 200B free tier; raw price $0.10/1B | **$0.00** |
| AMP managed collector | Not used in MVP; use app remote-write or customer-managed ADOT sidecar | $0.04/collector-hour only if enabled | **$0.00** |
| **AMP total, current demo scope** |  |  | **~$0.00/month** |

Conservative no-free-tier view:

```text
Ingest: 907,200 × $0.00000009 ~= $0.0816
Query : 21,772,800 × $0.0000000001 ~= $0.0022
Storage: negligible for this volume
Total : still < $0.10/month before dashboard/ad-hoc queries
```

### 5.3 Contract peak check: 50,000 events/sec

The AI telemetry contract says the telemetry pipeline design ceiling is **50,000 events/sec peak**, while demo scope is only tens of events/sec.

AMP feasibility for that ceiling:

| Constraint | AMP fact | Fit |
|---|---:|---|
| Remote write ingestion | 70,000 samples/sec documented for `RemoteWrite` | **Passes 50,000/sec peak** with limited headroom |
| Workspace ingestion quota | ~1,666,666 samples/sec default per workspace | **Passes** |
| Active series | 50M active series default | **Likely passes for demo; production cardinality must be controlled** |
| Request size | 1MB ingestion/query request size limit | **Requires batching/collector config for high peak** |

Important:

> AMP is feasible for the stated 50k/sec design ceiling, but only if CDO controls label cardinality and uses a proper collector/remote-write batching strategy. High-cardinality labels such as `request_id`, `trace_id`, or `prediction_id` must not become Prometheus labels.

---

## 6. Monthly cost estimate after full migration

### 6.1 Main estimate: x86 Fargate, same doc-priced topology

Assumptions:

- Region: `us-east-1`.
- Same 5 always-on ECS Fargate tasks as current docs.
- Same task size: 0.5 vCPU / 1GB.
- Same doc-priced ALB model: one ALB-hour stream + 1 average LCU.
- Same network model: 1 zonal NAT + S3/DynamoDB Gateway Endpoints.
- Timestream for InfluxDB removed.
- AMP used as TSDB/evidence store.
- AMP managed collector is not used; app or ADOT sidecar remote-writes to AMP.

| Component | us-east-1 estimate/month | Calculation / note |
|---|---:|---|
| ECS Fargate x86 | **$90.10** | 5 tasks × 730h × (0.5 × $0.04048 + 1GB × $0.004445) |
| ALB + 1 LCU | **$22.27** | $0.0225/h × 730 + $0.008/LCU-h × 730 |
| NAT Gateway + ~12GB data | **$33.39** | $0.045/h × 730 + 12GB × $0.045 |
| AMP workspace | **~$0.00** | Current demo volume fits free tier; no fixed instance-hour charge |
| DynamoDB audit/policy | **$0.10** | Same low-volume on-demand audit/policy model |
| EventBridge + SQS/DLQ | **$0.05** | Same ~26k jobs/month |
| S3 evidence/baseline/failure buffer | **$0.35** | Same evidence/failure-buffer model |
| CloudWatch + SNS | **$8.00** | Same logs/metrics/dashboard/alarms estimate |
| Secrets Manager + KMS | **$3.40** | Kept conservative; InfluxDB token secrets removed but other secrets/KMS remain |
| ECR | **$0.50** | Midpoint of small-image estimate |
| **Full always-on total** | **~$158.16/month** | Under $200 by about **$41.84** |
| **+20% ops buffer** | **~$189.79/month** | Still under $200 by about **$10.21** |

### 6.2 ARM64 mitigation variant

If all images support ARM64/Graviton:

| Component | Estimate/month |
|---|---:|
| ECS Fargate ARM | **$72.09** |
| All other components same as main estimate | **$68.06** |
| **Total with ARM64** | **~$140.15/month** |
| **+20% ops buffer** | **~$168.18/month** |

### 6.3 Sensitivity: Service Connect proxy headroom

The accepted topology uses ECS Service Connect for Worker → AI routing. AWS docs state there is no additional charge for Service Connect itself and Cloud Map usage through Service Connect is not charged separately. The cost sensitivity is therefore Fargate task sizing: the Service Connect proxy needs CPU/memory headroom inside the task.

If current 0.5 vCPU / 1GB task sizing has enough headroom, the x86 estimate remains:

```text
Full always-on total = ~$158.16/month
With 20% buffer    = ~$189.79/month
```

If the proxy forces one or more tasks to move to the next Fargate size, re-estimate compute before claiming the buffered budget.

---

## 7. Cost comparison against current Singapore + InfluxDB decision

| Scenario | Monthly estimate | 20% buffer | Budget fit |
|---|---:|---:|---|
| `ap-southeast-1` + Timestream for InfluxDB | **~$296.04** | **~$355.25** | Does not fit $200/month |
| Migrated `us-east-1` + AMP, x86 Fargate + Service Connect | **~$158.16** | **~$189.79** | Fits $200/month if Service Connect proxy does not force task upsize |
| Migrated `us-east-1` + AMP, ARM64 Fargate | **~$140.15** | **~$168.18** | Stronger budget fit |

Primary saving:

```text
Remove Timestream for InfluxDB fixed cost: -$103.66/month
Region price reduction for Fargate/NAT/ALB: additional savings
AMP usage at demo scope: effectively near-zero
```

---

## 8. Lead-time and AI contract feasibility

### 8.1 Contract requirements that matter

From the AI contracts and CDO docs:

| Requirement | Value |
|---|---|
| Telemetry frequency | 1 minute |
| AI request window | `signal_window` must include at least 120 minutes of recent data |
| Prediction cadence | 5 minutes |
| Lead time | Minimum ≥15 minutes, target 30 minutes if possible |
| AI endpoint | `POST /v1/predict` |
| AI auth | IAM SigV4 in W12 final |
| AI p99 latency | <500ms |
| AI throughput | 100 RPS |
| AI availability | 99.5% |
| AI Engine compute | ECS Fargate, min 2/max 4 tasks, private subnet, ECS Service Connect service |
| Audit | Every prediction/fallback decision must be logged |
| Fallback | Static threshold fallback when AI is unavailable/timeout/invalid |

### 8.2 Does `us-east-1` break lead time ≥15 minutes?

No, not by itself.

The lead-time requirement is controlled mainly by:

```text
telemetry frequency + TSDB write latency + query latency + prediction cadence + AI latency + alert/audit path
```

The migration keeps the important timings:

| Timing component | After migration |
|---|---|
| Telemetry frequency | Still 1 minute |
| Prediction cadence | Still every 5 minutes |
| Query window | Still 120 minutes |
| AI call path | Still private ECS Service Connect path inside the same VPC/region if AI Engine also migrates to `us-east-1` |
| AI p99 latency | Should remain governed by ECS/AI task sizing, not region name |
| Audit/fallback | Still DynamoDB/SQS/SNS in-region |

Therefore:

> If Telemetry API, AMP workspace, Prediction Worker, AI Engine, SQS, DynamoDB, S3, and CloudWatch are all in `us-east-1`, the platform should still satisfy the 15-minute lead-time requirement. A 5-minute cadence leaves at least three prediction opportunities before a 15-minute lead-time threshold, assuming the AI model can detect the drift pattern from the 120-minute window.

### 8.3 What can break the lead-time contract?

| Risk | Impact | Mitigation |
|---|---|---|
| Only CDO moves to `us-east-1`, but producers/demo services stay in Singapore | Cross-region ingest latency/jitter and possible data-transfer complexity | Move the whole demo runtime together, or explicitly document cross-region producer latency and test p99 emit SLA <60s |
| AMP query is written too broadly | More query samples, slower Worker, higher cost | PromQL must filter by `tenant_id`, `service_id`, metric name, and exact time range |
| Prometheus label cardinality explodes | Higher cost, query latency, active-series risk | Do not label by `request_id`, `trace_id`, `prediction_id`, raw endpoint path with IDs, or user identifiers |
| ADOT/remote-write batching misconfigured | Metric gaps; AI rejects gap >1 minute or <120 points | Configure retries/queue/batch, and keep S3 failure buffer/replay path |
| AI Engine remains in old region while Worker moves | Worker -> AI path becomes cross-region/public/private-complex, not current Service Connect design | Migrate AI Engine with CDO platform, or treat as a formal contract exception |
| CDO docs still say Singapore is official | Governance/review failure even if infra works | Update CDO docs/ADR before claiming final compliance; frozen AI contracts do not need edits |

### 8.4 Contract compatibility verdict

| Contract area | Verdict after migration |
|---|---|
| `POST /v1/predict` API schema | **Compatible**; unchanged |
| IAM SigV4 auth | **Compatible**; AMP also uses IAM/SigV4, but AI auth remains separate |
| 120-minute `signal_window` | **Compatible** if Worker queries PromQL correctly and aligns 1-minute buckets |
| 1-minute telemetry | **Compatible** if AMP ingest path has no gaps and remote-write is reliable |
| 15-minute lead time | **Compatible** if all runtime components are co-located in `us-east-1` |
| 90-day retention | **Compatible**; AMP default retention is 150 days |
| AI deployment on ECS Fargate | **Compatible** if AI Engine is also deployed in `us-east-1` private subnets |
| CDO region wording | **Not compatible without CDO doc/ADR update** because current CDO docs lock `ap-southeast-1`; frozen AI contracts remain compatible |

---

## 9. Security and compliance impact

Positive changes:

- AMP uses IAM-integrated APIs instead of InfluxDB app tokens for write/query.
- Fewer long-lived TSDB credentials in Secrets Manager.
- AMP is managed, Multi-AZ, and serverless; no TSDB instance admin credential is needed for app tasks.
- AMP supports PrivateLink for private connectivity if needed.

New controls required:

| Control | Required action |
|---|---|
| IAM least privilege | Add scoped AMP permissions for write/query, e.g. workspace-specific remote write/query access. |
| Tenant isolation | Enforce `tenant_id` as required Prometheus label and always filter by it in PromQL. |
| Label hygiene | Deny PII labels and high-cardinality labels. |
| Query discipline | Runtime PromQL must use `tenant_id`, `service_id`, metric names, and `[120m]` or exact range selectors. |
| Audit continuity | DynamoDB audit remains source of decision evidence; do not replace audit with AMP. |
| Failure handling | Keep S3 failure buffer/replay if remote write fails. |
| Retention | Configure AMP retention if the default 150 days is not desired, but it already satisfies ≥90 days. |

---

## 10. Required doc/ADR changes if this migration is accepted

Because the CDO docs currently lock `ap-southeast-1` and Timestream for InfluxDB, accepting this migration requires CDO documentation and ADR updates before Terraform implementation.

Minimum documentation changes:

1. **`docs/02_infra_design.md`**
   - Change final region to `us-east-1`.
   - Replace Timestream for InfluxDB data model with AMP Prometheus labels/PromQL model.
   - Update component table cost from `~$296.04` to the AMP estimate.
   - Update failure mode wording from InfluxDB write/query to AMP remote write/query.

2. **`docs/03_security_design.md`**
   - Remove InfluxDB token model from app config.
   - Add AMP IAM/SigV4 permissions and label-based tenant isolation.
   - Add Prometheus label cardinality/PII guardrails.

3. **`docs/04_deployment_design.md`**
   - Update data module description from Timestream for InfluxDB to AMP workspace.
   - Update module responsibilities for ADOT/remote write config if implemented in ECS task definitions.

4. **`docs/05_cost_analysis.md`**
   - Replace Singapore + InfluxDB cost table with us-east-1 + AMP table if this becomes final.
   - Keep a migration comparison table for defendability.

5. **`docs/08_adrs.md`**
   - Add a new ADR superseding ADR-010 if the team accepts AMP.
   - Do not delete ADR-004/ADR-010; mark the new decision as the latest accepted direction.

6. **AI contracts**
   - No frozen AI contract edit is required for this decision: the deployment contract already defaults `AWS_REGION` to `us-east-1` and states the engine is region-agnostic by CDO deployment region.
   - The API schema, IAM SigV4 auth, telemetry cadence, 120-minute window, AI p99/throughput/availability, audit and fallback semantics do not change.

---

## 11. Recommendation

### Recommended decision if budget is the priority

Adopt `us-east-1` + AMP only if the team is willing to update the docs and record a formal ADR/change request.

Why:

- It brings the full-month always-on estimate back under $200.
- It removes the fixed `db.influx.medium` cost that currently dominates the budget gap.
- AMP’s default 150-day retention satisfies the 90-day telemetry retention target.
- AMP capacity/quota is enough for the current demo path and the stated 50k events/sec design ceiling, assuming sane labels and remote-write batching.

### Recommended decision if contract stability is the priority

Stay with `ap-southeast-1` + Timestream for InfluxDB only if contract stability and avoiding a TSDB/query-model migration are more important than full-month always-on budget fit.

Why:

- Current docs and ADRs already align around Singapore + InfluxDB.
- No query/data-model migration is needed.
- Less risk of contract review friction.
- Full-month always-on cost remains above the $200/month target unless the team accepts mitigation or a budget exception.

### My technical verdict

```text
us-east-1 + AMP is cost-superior and technically feasible,
but it is not a drop-in replacement.
```

It should be treated as an architecture migration:

```text
Region change + TSDB product change + query language change + IAM model change + evidence format change
```

Now that this migration is accepted, the next step is to keep the main CDO docs/ADR as the source of truth, then update Terraform only after the documentation decision is accepted. Do not implement Terraform directly from this analysis file.

---

## 12. Sources checked

AWS Knowledge / Pricing evidence used in this estimate:

- Amazon Managed Service for Prometheus pricing page:
  - pay-as-you-go on ingested samples, storage, query samples, and collector usage
  - free tier: 40M ingested samples, 200B query samples, 10GB storage
  - no Data Transfer IN charge for AMP
- Amazon Managed Service for Prometheus docs:
  - serverless Prometheus-compatible service
  - Multi-AZ design; data replicated across three AZs in-region
  - default retention 150 days; configurable up to 1095 days
  - supported region includes `us-east-1`
- AMP RemoteWrite API docs:
  - remote write endpoint path `/workspaces/{workspaceId}/api/v1/remote_write`
  - documented ingestion rate 70,000 samples/sec and burst 1,000,000 samples
- AMP service quotas docs:
  - active series per workspace 50M default
  - ingestion rate per workspace around 1,666,666 samples/sec default
- ECS + AMP docs:
  - ECS/Fargate can export task/application metrics to AMP using AWS Distro for OpenTelemetry sidecar
- AWS Pricing API checks for `us-east-1`:
  - `AmazonPrometheus`
  - `AmazonECS`
  - `AWSELB`
  - `AmazonEC2` NAT Gateway
- AWS regional availability check:
  - Amazon Managed Service for Prometheus, ECS, ELB, and VPC are available in `us-east-1`.
