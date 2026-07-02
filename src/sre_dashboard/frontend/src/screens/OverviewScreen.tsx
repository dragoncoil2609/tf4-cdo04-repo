import { useEffect, useState } from "react";
import { api } from "../api/client";
import { ServiceCard } from "../components/ServiceCard";
import type { OverviewResponse } from "../api/types";

interface OverviewScreenProps {
  tenantId: string;
  onTenantChange: (tenantId: string) => void;
  onOpenMetrics: (serviceName: string) => void;
}

export function OverviewScreen({ tenantId, onTenantChange, onOpenMetrics }: OverviewScreenProps) {
  const [tenants, setTenants] = useState<string[]>([]);
  const [overview, setOverview] = useState<OverviewResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    api
      .tenants()
      .then((response) => {
        setTenants(response.tenants);
        if (!tenantId && response.tenants[0]) onTenantChange(response.tenants[0]);
      })
      .catch((err: Error) => setError(err.message));
  }, [tenantId, onTenantChange]);

  useEffect(() => {
    if (!tenantId) return;
    setLoading(true);
    api
      .overview(tenantId)
      .then(setOverview)
      .catch((err: Error) => setError(err.message))
      .finally(() => setLoading(false));
  }, [tenantId]);

  return (
    <section className="stack">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <h1>Overview</h1>
          <p className="muted">Tenant-level operational summary.</p>
        </div>
        <select value={tenantId} onChange={(event) => onTenantChange(event.target.value)}>
          {tenants.map((tenant) => (
            <option key={tenant}>{tenant}</option>
          ))}
        </select>
      </div>
      {error ? <div className="banner error">{error}</div> : null}
      {overview?.errors?.map((item) => <div className="banner error" key={item}>{item}</div>)}
      {loading ? <p>Loading overview...</p> : null}
      {!loading && overview && !overview.services.length ? <p>No operational data found for this tenant.</p> : null}
      <div className="grid three">
        {overview?.services.map((service) => (
          <ServiceCard key={service.service_name} service={service} onOpen={onOpenMetrics} />
        ))}
      </div>
      <section className="panel">
        <h2>Policies</h2>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Service</th><th>Threshold</th><th>Enabled</th></tr></thead>
            <tbody>
              {overview?.policies.map((policy) => (
                <tr key={policy.service_name}>
                  <td>{policy.service_name}</td>
                  <td>{policy.static_threshold}</td>
                  <td>{String(policy.enabled)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      <section className="panel">
        <h2>Recent alarms</h2>
        <pre className="muted">{JSON.stringify(overview?.recent_alarms ?? [], null, 2)}</pre>
      </section>
    </section>
  );
}
