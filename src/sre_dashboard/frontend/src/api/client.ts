import type {
  AlarmsResponse,
  AllMetricsResponse,
  AuditsResponse,
  EcsResponse,
  LoginRequest,
  LoginResponse,
  OverviewResponse,
  PoliciesResponse,
  PolicyUpdateRequest,
  PolicyUpdateResponse,
  Profile,
  ProbesResponse,
  QueueResponse,
  SessionState,
  TenantsResponse,
} from "./types";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: unknown,
  ) {
    super(message);
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init.headers,
    },
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const message =
      typeof body === "object" && body && "detail" in body
        ? String(body.detail)
        : `Request failed: ${response.status}`;
    throw new ApiError(message, response.status, body);
  }

  return body as T;
}

const query = (params: Record<string, string | number | null | undefined>) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== null && value !== undefined && value !== "") {
      search.set(key, String(value));
    }
  }
  const qs = search.toString();
  return qs ? `?${qs}` : "";
};

export const api = {
  health: () => request<{ status: string; service: string }>("/health"),
  profiles: () => request<{ profiles: Profile[] }>("/api/profiles"),
  session: () => request<SessionState>("/api/session"),
  login: (body: LoginRequest) =>
    request<LoginResponse>("/api/session", {
      method: "POST",
      body: JSON.stringify(body),
    }),
  logout: () => request<{ status: string }>("/api/session", { method: "DELETE" }),
  probes: () => request<ProbesResponse>("/api/probes"),
  tenants: () => request<TenantsResponse>("/api/tenants"),
  overview: (tenantId: string) =>
    request<OverviewResponse>(`/api/overview${query({ tenant_id: tenantId })}`),
  metrics: (tenantId: string, serviceId: string, rangeMinutes = 120) =>
    request<AllMetricsResponse>(
      `/api/metrics/${encodeURIComponent(serviceId)}${query({ tenant_id: tenantId, range_minutes: rangeMinutes })}`,
    ),
  audits: (tenantId: string, serviceId?: string, limit = 50) =>
    request<AuditsResponse>(`/api/audits${query({ tenant_id: tenantId, service_id: serviceId, limit })}`),
  policies: (tenantId?: string) => request<PoliciesResponse>(`/api/policies${query({ tenant_id: tenantId })}`),
  updatePolicy: (tenantId: string, serviceName: string, body: PolicyUpdateRequest) =>
    request<PolicyUpdateResponse>(
      `/api/policies/${encodeURIComponent(tenantId)}/${encodeURIComponent(serviceName)}`,
      { method: "PUT", body: JSON.stringify(body) },
    ),
  alarms: () => request<AlarmsResponse>("/api/alarms"),
  queue: () => request<QueueResponse>("/api/queue"),
  ecs: () => request<EcsResponse>("/api/ecs"),
};
