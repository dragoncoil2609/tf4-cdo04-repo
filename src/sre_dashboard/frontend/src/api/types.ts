export interface Profile {
  name: string;
  source: string;
}

export interface SessionState {
  profile: string | null;
  account_id: string | null;
  region: string;
  logged_in_at: string | null;
  is_logged_in: boolean;
}

export interface LoginRequest {
  profile?: string;
  region?: string;
}

export interface LoginResponse {
  status: "ok" | "error";
  profile?: string;
  account_id?: string;
  arn?: string;
  region?: string;
  detail?: string;
  error?: string;
}

export interface ProbeResult {
  status: "ok" | "error" | "denied" | "skipped";
  detail?: string;
  account_id?: string;
  arn?: string;
  table?: string;
  queue_url?: string;
  approximate_number_of_messages?: number;
  approximate_number_of_messages_not_visible?: number;
  alarm_count?: number;
  workspace_count?: number;
  service_arns?: string[];
}

export interface ProbesResponse {
  sts: ProbeResult;
  amp: ProbeResult;
  dynamodb_audit: ProbeResult;
  dynamodb_policies: ProbeResult;
  sqs: ProbeResult;
  cloudwatch: ProbeResult;
  ecs: ProbeResult;
}

export interface TenantsResponse {
  tenants: string[];
}

export interface ServicesResponse {
  tenant_id: string;
  services: string[];
}

export interface ServiceOverview {
  service_name: string;
  latest_decision: string;
  latest_score: number;
  anomaly: boolean;
  severity: number;
}

export interface PolicySummary {
  tenant_id: string;
  service_name: string;
  static_threshold: number;
  enabled: boolean;
}

export interface OverviewResponse {
  tenant_id: string;
  services: ServiceOverview[];
  recent_alarms: unknown[];
  policies: PolicySummary[];
  errors: string[];
}

export interface MetricValue {
  timestamp: number;
  value: number;
}

export interface MetricSeries {
  metric: Record<string, string>;
  values: MetricValue[];
}

export interface MetricQueryResult {
  status: "ok" | "error";
  metric_type: string;
  tenant_id: string;
  service_id: string;
  series: MetricSeries[];
  query_range: { start: number; end: number; step: number };
}

export interface AllMetricsResponse {
  status: string;
  tenant_id: string;
  service_id: string;
  range_minutes: number;
  metrics: Record<MetricType, MetricQueryResult>;
}

export type MetricType =
  | "cpu_usage_percent"
  | "memory_usage_percent"
  | "active_connections"
  | "db_connection_pool_pct"
  | "queue_depth"
  | "cache_hit_rate_pct"
  | "api_latency_ms";

export interface AuditRecord {
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

export interface AuditsResponse {
  tenant_id: string;
  service_id: string | null;
  count: number;
  records: AuditRecord[];
}

export interface Policy {
  tenant_id: string;
  service_name: string;
  static_threshold: number;
  enabled: boolean;
}

export interface PoliciesResponse {
  tenant_id: string | null;
  policies: Policy[];
}

export interface PolicyUpdateRequest {
  static_threshold: number;
  enabled?: boolean;
  expected_old_value?: number;
}

export interface PolicyUpdateResponse {
  status: "ok" | "error" | "conflict";
  tenant_id?: string;
  service_name?: string;
  static_threshold?: number;
  enabled?: boolean;
  detail?: string;
}

export interface CloudWatchAlarm {
  alarm_name: string;
  state_value: string;
  state_reason: string;
  metric_name: string;
  namespace: string;
  threshold: number;
  comparison_operator: string;
}

export interface AlarmsResponse {
  alarms: CloudWatchAlarm[];
  count: number;
}

export interface QueueInfo {
  queue_url: string;
  queue_name?: string;
  approximate_number_of_messages: number;
  approximate_number_of_messages_not_visible: number;
  status?: ProbeResult["status"];
  detail?: string;
}

export interface QueueResponse {
  queues: QueueInfo[];
  count: number;
}

export interface EcsService {
  service_name: string;
  status: string;
  desired_count: number;
  running_count: number;
  pending_count: number;
  launch_type: string;
  task_definition: string;
  cluster_arn: string;
}

export interface EcsResponse {
  ecs_services: EcsService[];
  count: number;
}
