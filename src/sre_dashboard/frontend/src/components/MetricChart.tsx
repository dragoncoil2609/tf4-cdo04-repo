import type { MetricQueryResult } from "../api/types";

interface MetricChartProps {
  title: string;
  label: string;
  result?: MetricQueryResult;
  threshold?: number;
}

export function MetricChart({ title, label, result, threshold }: MetricChartProps) {
  const values = result?.series.flatMap((series) => series.values) ?? [];
  const max = Math.max(threshold ?? 0, ...values.map((point) => point.value), 1);
  const bars = values.slice(-48);

  return (
    <article className="card">
      <div className="row" style={{ justifyContent: "space-between" }}>
        <div>
          <h3>{title}</h3>
          <span className="muted">{label}</span>
        </div>
        <span className={`status ${result?.status ?? "skipped"}`}>{result?.status ?? "no data"}</span>
      </div>
      {bars.length ? (
        <div className="chart" aria-label={`${title} chart`}>
          {bars.map((point) => (
            <span
              className="bar"
              key={`${point.timestamp}-${point.value}`}
              title={`${new Date(point.timestamp * 1000).toLocaleString()} — ${point.value}`}
              style={{ height: `${Math.max(4, (point.value / max) * 100)}%` }}
            />
          ))}
        </div>
      ) : (
        <p className="muted">No metric data available for this time range.</p>
      )}
      {threshold !== undefined ? <p className="muted">Policy threshold: {threshold}%</p> : null}
    </article>
  );
}
