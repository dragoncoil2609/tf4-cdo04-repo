import { useState } from "react";
import { api } from "../api/client";
import type { ProbeResult, ProbesResponse } from "../api/types";

const probeNames: (keyof ProbesResponse)[] = ["sts", "amp", "dynamodb_audit", "dynamodb_policies", "sqs", "cloudwatch", "ecs"];

function ProbeCard({ name, result }: { name: string; result?: ProbeResult }) {
  const status = result?.status ?? "skipped";
  return (
    <article className="card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h3>{name}</h3>
        <span className={`status ${status}`}>{status}</span>
      </div>
      <p className="muted">{result?.detail ?? result?.arn ?? result?.table ?? result?.queue_url ?? `${name} probe`}</p>
      {result?.alarm_count !== undefined ? <p>Alarms: {result.alarm_count}</p> : null}
      {result?.workspace_count !== undefined ? <p>Workspaces: {result.workspace_count}</p> : null}
      {result?.service_arns?.length ? <p>ECS services: {result.service_arns.length}</p> : null}
    </article>
  );
}

export function ProbesScreen() {
  const [probes, setProbes] = useState<ProbesResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const run = () => {
    setLoading(true);
    setError("");
    api.probes().then(setProbes).catch((err: Error) => setError(err.message)).finally(() => setLoading(false));
  };

  return (
    <section className="stack">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <h1>Probes</h1>
          <p className="muted">Read-only AWS permission checks.</p>
        </div>
        <button className="primary" type="button" onClick={run} disabled={loading}>
          {loading ? "Probing..." : "Run Probes"}
        </button>
      </div>
      {error ? <div className="banner error">{error}</div> : null}
      <div className="grid three">
        {probeNames.map((name) => <ProbeCard key={name} name={name} result={probes?.[name]} />)}
      </div>
    </section>
  );
}
