import { useEffect, useState } from "react";
import { api } from "../api/client";
import { MetricChart } from "../components/MetricChart";
import type { AllMetricsResponse, AuditRecord, MetricType, Policy } from "../api/types";

const metricSpecs: Record<MetricType, string> = {
  cpu_usage_percent: "CPU %",
  memory_usage_percent: "Memory %",
  active_connections: "Connections",
  db_connection_pool_pct: "Connection Pool %",
  queue_depth: "Queue Depth",
  cache_hit_rate_pct: "Cache Hit Rate %",
  api_latency_ms: "Latency (ms)",
};

const metricTypes = Object.keys(metricSpecs) as MetricType[];

interface MetricsScreenProps {
  tenantId: string;
  serviceId: string;
  onServiceChange: (serviceId: string) => void;
}

export function MetricsScreen({ tenantId, serviceId, onServiceChange }: MetricsScreenProps) {
  const [services, setServices] = useState<string[]>([]);
  const [rangeMinutes, setRangeMinutes] = useState(120);
  const [metrics, setMetrics] = useState<AllMetricsResponse | null>(null);
  const [audits, setAudits] = useState<AuditRecord[]>([]);
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!tenantId) return;
    api.overview(tenantId).then((response) => {
      const names = response.services.map((service) => service.service_name);
      setServices(names);
      if (!serviceId && names[0]) onServiceChange(names[0]);
    }).catch((err: Error) => setError(err.message));
    api.policies(tenantId).then((response) => setPolicies(response.policies)).catch(() => undefined);
  }, [tenantId, serviceId, onServiceChange]);

  useEffect(() => {
    if (!tenantId || !serviceId) return;
    setError("");
    api.metrics(tenantId, serviceId, rangeMinutes).then(setMetrics).catch((err: Error) => setError(err.message));
    api.audits(tenantId, serviceId).then((response) => setAudits(response.records)).catch((err: Error) => setError(err.message));
  }, [tenantId, serviceId, rangeMinutes]);

  const threshold = policies.find((policy) => policy.service_name === serviceId)?.static_threshold;

  return (
    <section className="stack">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <h1>Metrics</h1>
          <p className="muted">Structured metrics only. No raw PromQL in browser.</p>
        </div>
        <div className="row">
          <select value={serviceId} onChange={(event) => onServiceChange(event.target.value)}>
            {services.map((name) => <option key={name}>{name}</option>)}
          </select>
          <select value={rangeMinutes} onChange={(event) => setRangeMinutes(Number(event.target.value))}>
            <option value={30}>30 min</option>
            <option value={60}>1 hour</option>
            <option value={120}>2 hours</option>
            <option value={360}>6 hours</option>
          </select>
        </div>
      </div>
      {error ? <div className="banner error">{error}</div> : null}
      <div className="grid two">
        {metricTypes.map((metricType) => (
          <MetricChart
            key={metricType}
            title={metricType}
            label={metricSpecs[metricType]}
            result={metrics?.metrics?.[metricType]}
            threshold={threshold}
          />
        ))}
      </div>
      <section className="panel">
        <h2>Audit log</h2>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Time</th><th>Service</th><th>Decision</th><th>Score</th><th>Anomaly</th><th>Reasoning</th></tr></thead>
            <tbody>
              {audits.map((record) => (
                <tr key={record.prediction_id || `${record.service_name}-${record.timestamp}`}>
                  <td>{record.service_time || new Date(record.timestamp * 1000).toLocaleString()}</td>
                  <td>{record.service_name}</td>
                  <td>{record.decision}</td>
                  <td>{record.score}</td>
                  <td>{String(record.anomaly)}</td>
                  <td>{record.reasoning}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </section>
  );
}
