# SRE Dashboard — Frontend Handoff Document

## Overview

This document specifies the API contracts, TypeScript interfaces, UI states,
and wireframes for the CDO SRE Dashboard frontend. The backend is a local-only
FastAPI service bound to `127.0.0.1:8001`.

**Critical Rules for Frontend:**
1. **No AWS SDK in the browser** — all AWS calls go through the backend API.
2. **No AWS credentials in the frontend** — credentials exist only in the backend process.
3. **No raw PromQL input in the browser** — all PromQL is constructed server-side.
4. **No SQS ReceiveMessage path** — the dashboard only reads queue attributes.

---

## Screens

### 1. Session / Login Screen

**Purpose:** Select an AWS SSO profile and log in.

**Elements:**
- Dropdown of available AWS profiles (from `GET /api/profiles`)
- Region input (default `us-east-1`)
- "Login" button
- Status message (loading, error, success)

**API Calls:**
- `GET /api/profiles` — populate profile dropdown
- `POST /api/session` — log in

**States:**
- **Loading:** "Loading profiles..." spinner while fetching profiles
- **Empty:** No profiles found — message "No AWS profiles found. Run `aws configure`."
- **Denied:** Login fails — show error detail (e.g., "SSO login failed. Run `aws sso login`.")
- **Logged In:** Redirect to dashboard overview; show profile name + account ID

---

### 2. Dashboard Overview Screen

**Purpose:** Tenant-level operational summary.

**Elements:**
- Tenant selector (dropdown from `GET /api/tenants`)
- Service cards with latest decision, score, anomaly flag
- Policy summary section
- Recent alarms list
- Error alerts for section-level probe failures

**API Calls:**
- `GET /api/tenants` — populate tenant selector
- `GET /api/overview?tenant_id=...` — get aggregated data

**States:**
- **Loading:** Skeleton cards while fetching
- **Empty:** No data for tenant — "No operational data found for this tenant."
- **Error:** Section-level error messages from overview response
- **Denied:** Probe failure — red banner "Access denied to [service]"

---

### 3. Service Detail / Metrics Screen

**Purpose:** View time-series metrics for a single service.

**Elements:**
- Service selector
- Metric type tabs or chart grid (7 charts)
- Range selector (30 min, 1 hour, 2 hours, 6 hours)
- Audit log table below charts

**API Calls:**
- `GET /api/metrics/{service_id}?tenant_id=...&range_minutes=...` — all 7 metrics
- `GET /api/audits?tenant_id=...&service_id=...&limit=50` — audit logs

**States:**
- **Loading:** Chart placeholders with shimmer animation
- **Empty:** No metrics available — "No metric data available for this time range."
- **Error:** AMP query error — orange banner with error detail
- **Denied:** Permission denied to AMP — "Access denied: cannot query AMP workspace"

---

### 4. Policies Screen

**Purpose:** View and edit service policies.

**Elements:**
- Tenant filter
- Policy table (service_name, static_threshold, enabled)
- Inline edit with confirmation dialog
- "Update" button

**API Calls:**
- `GET /api/policies?tenant_id=...` — list policies
- `PUT /api/policies/{tenant_id}/{service_name}` — update policy

**States:**
- **Loading:** Skeleton table rows
- **Empty:** No policies found — "No policies configured for this tenant."
- **Edit Confirmation:** Modal: "Update threshold for {service} from {old} to {new}?"
- **Conflict:** If `expected_old_value` doesn't match — error "Policy was modified by another session. Reload and try again."
- **Error:** Update fails — error toast

---

### 5. Probes / Infrastructure Health Screen

**Purpose:** Run and view AWS permission probes.

**Elements:**
- "Run Probes" button
- Probe result cards (STS, AMP, DynamoDB, SQS, CloudWatch, ECS)
- Per-service status indicator (ok / error / denied / skipped)

**API Calls:**
- `GET /api/probes` — run all probes

**States:**
- **Loading:** All cards show "Probing..." animation
- **OK:** Green checkmark + result summary
- **Error:** Red X + error detail
- **Denied:** Orange warning + "Access denied" message
- **Skipped:** Gray — "No SQS queue URL configured"

---

### 6. Alarms / Queue / ECS Screen

**Purpose:** Browse infrastructure state.

**Elements:**
- Three tabbed sections: Alarms | Queue | ECS
- Sortable/filterable tables

**API Calls:**
- `GET /api/alarms` — CloudWatch alarms
- `GET /api/queue` — SQS queues
- `GET /api/ecs` — ECS services

**States:**
- **Loading:** Table skeleton
- **Empty:** "No alarms configured." / "No queues found." / "No ECS services."
- **Error:** Red error banner
- **Denied:** "Access denied to [service]."

---

## API Contracts & TypeScript Interfaces

### Session

```typescript
interface Profile {
  name: string;
  source: string;
}

interface SessionState {
  profile: string | null;
  account_id: string | null;
  region: string;
  logged_in_at: string | null;
  is_logged_in: boolean;
}

interface LoginResponse {
  status: "ok" | "error";
  profile?: string;
  account_id?: string;
  arn?: string;
  region?: string;
  detail?: string;
  error?: string;
}

interface LoginRequest {
  profile?: string;
  region?: string;
}
```

### Probes

```typescript
interface ProbeResult {
  status: "ok" | "error" | "denied" | "skipped";
  detail?: string;
  account_id?: string;
  arn?: string;
  table?: string;
  queue_url?: string;
  approximate_number_of_messages?: number;
  alarm_count?: number;
  workspace_count?: number;
  service_arns?: string[];
}

interface ProbesResponse {
  sts: ProbeResult;
  amp: ProbeResult;
  dynamodb_audit: ProbeResult;
  dynamodb_policies: ProbeResult;
  sqs: ProbeResult;
  cloudwatch: ProbeResult;
  ecs: ProbeResult;
}
```

### Tenants & Services & Overview

```typescript
interface TenantsResponse {
  tenants: string[];
}

interface ServicesResponse {
  tenant_id: string;
  services: string[];
}

interface ServiceOverview {
  service_name: string;
  latest_decision: string;
  latest_score: number;
  anomaly: boolean;
  severity: number;
}

interface PolicySummary {
  tenant_id: string;
  service_name: string;
  static_threshold: number;
  enabled: boolean;
}

interface OverviewResponse {
  tenant_id: string;
  services: ServiceOverview[];
  recent_alarms: any[];
  policies: PolicySummary[];
  errors: string[];
}
```

### Metrics

```typescript
interface MetricValue {
  timestamp: number;
  value: number;
}

interface MetricSeries {
  metric: Record<string, string>;
  values: MetricValue[];
}

interface MetricQueryResult {
  status: "ok" | "error";
  metric_type: string;
  tenant_id: string;
  service_id: string;
  series: MetricSeries[];
  query_range: { start: number; end: number; step: number };
}

interface AllMetricsResponse {
  status: string;
  tenant_id: string;
  service_id: string;
  range_minutes: number;
  metrics: Record<string, MetricQueryResult>;
}

type MetricType =
  | "cpu_usage_percent"
  | "memory_usage_percent"
  | "active_connections"
  | "db_connection_pool_pct"
  | "queue_depth"
  | "cache_hit_rate_pct"
  | "api_latency_ms";
```

### Audits

```typescript
interface AuditRecord {
  tenant_id: string;
  service_name: string;
  prediction_id: string;
  decision: string;
  prediction_source: string;
  score: number;
  anomaly: boolean;
  severity: number;
  reasoning: string;
  timestamp: number;
  service_time: string;
}

interface AuditsResponse {
  tenant_id: string;
  service_id: string | null;
  count: number;
  records: AuditRecord[];
}
```

### Policies

```typescript
interface Policy {
  tenant_id: string;
  service_name: string;
  static_threshold: number;
  enabled: boolean;
}

interface PoliciesResponse {
  tenant_id: string | null;
  policies: Policy[];
}

interface PolicyUpdateRequest {
  static_threshold: number;
  enabled?: boolean;
  expected_old_value?: number;
}

interface PolicyUpdateResponse {
  status: "ok" | "error" | "conflict";
  tenant_id?: string;
  service_name?: string;
  static_threshold?: number;
  enabled?: boolean;
  detail?: string;
}
```

### Alarms / Queue / ECS

```typescript
interface CloudWatchAlarm {
  alarm_name: string;
  state_value: string;
  state_reason: string;
  metric_name: string;
  namespace: string;
  threshold: number;
  comparison_operator: string;
}

interface QueueInfo {
  queue_url: string;
  queue_name: string;
  approximate_number_of_messages: number;
  approximate_number_of_messages_not_visible: number;
}

interface EcsService {
  service_name: string;
  status: string;
  desired_count: number;
  running_count: number;
  pending_count: number;
  launch_type: string;
  task_definition: string;
  cluster_arn: string;
}
```

---

## 7 Chart Specifications

Each of the 7 metric types must be rendered as a time-series line chart.

| Metric | Y-axis Label | Expected Range | Fill Policy |
|---|---|---|---|
| `cpu_usage_percent` | CPU % | 0–100 | forward_fill |
| `memory_usage_percent` | Memory % | 0–100 | forward_fill |
| `active_connections` | Connections | 0+ | forward_fill |
| `db_connection_pool_pct` | Connection Pool % | 0–100 | forward_fill |
| `queue_depth` | Queue Depth | 0+ | zero_fill |
| `cache_hit_rate_pct` | Cache Hit Rate % | 0–100 | forward_fill |
| `api_latency_ms` | Latency (ms) | 0+ | forward_fill |

**Chart Requirements:**
- X-axis: time (ISO 8601 format, local timezone)
- Y-axis: as specified above
- Line color: distinct per metric (use a consistent palette)
- Hover tooltip: timestamp + value
- Grid lines: light gray
- Responsive: full width of container, 200px–400px height
- Threshold line: optional dashed line at the service policy threshold (if available from `GET /api/policies`)

---

## Policy Edit Confirmation

When the user updates a policy threshold:

1. Open a confirmation modal:
   - Title: "Update Policy Threshold"
   - Body: "Change {service_name} threshold from {current_value}% to {new_value}%?"
   - Buttons: "Cancel" | "Confirm Update"
2. On confirm, call `PUT /api/policies/{tenant_id}/{service_name}`
3. Handle response:
   - `status: "ok"` — close modal, show success toast, refresh policy list
   - `status: "conflict"` — show error "Policy was modified. Reload and try again."
   - `status: "error"` — show error detail

---

## Wireframe Layout

```
+--------------------------------------------------------+
|  [Logo]  CDO SRE Dashboard    [Profile: admin] [Logout] |
+--------------------------------------------------------+
|  Navigation Bar                                          |
|  [Overview] [Metrics] [Policies] [Probes] [Infra]       |
+--------------------------------------------------------+
|                                                          |
|  +--------------------+  +--------------------+          |
|  | Service Card       |  | Service Card       |          |
|  | svc-a              |  | svc-b              |          |
|  | Decision: KEEP     |  | Decision: SCALE_UP |          |
|  | Score: 72          |  | Score: 91          |          |
|  | Anomaly: false     |  | Anomaly: true 🔴   |          |
|  +--------------------+  +--------------------+          |
|                                                          |
|  +--------------------------------------------------+    |
|  | Alarms Section                                    |    |
|  | No recent alarms.                                 |    |
|  +--------------------------------------------------+    |
|                                                          |
|  +--------------------------------------------------+    |
|  | Policies                                         |    |
|  | svc-a  | 85  | enabled  | [Edit]                 |    |
|  | svc-b  | 90  | enabled  | [Edit]                 |    |
|  +--------------------------------------------------+    |
+--------------------------------------------------------+
```

---

## Frontend Implementation Constraints

- Framework: any (React, Vue, Svelte) — backend is API-only
- HTTP client: `fetch` or `axios` — no AWS SDK
- Chart library: any (Chart.js, D3, ECharts, Recharts)
- No credentials stored in localStorage/sessionStorage/cookies
- No PromQL string construction in the browser
- All dates in ISO 8601, convert to local time for display
- API base URL: `http://127.0.0.1:8001`
