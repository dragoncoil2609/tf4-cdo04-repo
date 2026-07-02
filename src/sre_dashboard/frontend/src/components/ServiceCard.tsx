import type { ServiceOverview } from "../api/types";

interface ServiceCardProps {
  service: ServiceOverview;
  onOpen?: (serviceName: string) => void;
}

export function ServiceCard({ service, onOpen }: ServiceCardProps) {
  return (
    <article className="card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h3>{service.service_name}</h3>
        {service.anomaly ? <span title="anomaly">🔴</span> : <span className="muted">normal</span>}
      </div>
      <p>Decision: <strong>{service.latest_decision || "unknown"}</strong></p>
      <p>Score: <strong>{Number.isFinite(service.latest_score) ? service.latest_score : "n/a"}</strong></p>
      <p>Severity: <strong>{Number.isFinite(service.severity) ? service.severity : "n/a"}</strong></p>
      {onOpen ? (
        <button className="secondary" type="button" onClick={() => onOpen(service.service_name)}>
          Open metrics
        </button>
      ) : null}
    </article>
  );
}
