import { useEffect, useState } from "react";
import { api } from "../api/client";
import type { AlarmsResponse, EcsResponse, QueueResponse } from "../api/types";

type Tab = "alarms" | "queue" | "ecs";

export function InfraScreen() {
  const [tab, setTab] = useState<Tab>("alarms");
  const [alarms, setAlarms] = useState<AlarmsResponse | null>(null);
  const [queue, setQueue] = useState<QueueResponse | null>(null);
  const [ecs, setEcs] = useState<EcsResponse | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    setError("");
    if (tab === "alarms") api.alarms().then(setAlarms).catch((err: Error) => setError(err.message));
    if (tab === "queue") api.queue().then(setQueue).catch((err: Error) => setError(err.message));
    if (tab === "ecs") api.ecs().then(setEcs).catch((err: Error) => setError(err.message));
  }, [tab]);

  return (
    <section className="stack">
      <div>
        <h1>Infrastructure</h1>
        <p className="muted">CloudWatch alarms, SQS attributes, ECS service state.</p>
      </div>
      <div className="row">
        {(["alarms", "queue", "ecs"] as Tab[]).map((item) => (
          <button className={tab === item ? "primary" : "secondary"} key={item} type="button" onClick={() => setTab(item)}>
            {item.toUpperCase()}
          </button>
        ))}
      </div>
      {error ? <div className="banner error">{error}</div> : null}
      <section className="panel table-wrap">
        {tab === "alarms" ? (
          <table>
            <thead><tr><th>Name</th><th>State</th><th>Metric</th><th>Threshold</th><th>Reason</th></tr></thead>
            <tbody>
              {alarms?.alarms.map((alarm) => (
                <tr key={alarm.alarm_name}>
                  <td>{alarm.alarm_name}</td><td>{alarm.state_value}</td><td>{alarm.metric_name}</td><td>{alarm.threshold}</td><td>{alarm.state_reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
        {tab === "queue" ? (
          <table>
            <thead><tr><th>Queue</th><th>Visible</th><th>Not visible</th><th>Status</th></tr></thead>
            <tbody>
              {queue?.queues.map((item) => (
                <tr key={item.queue_url}>
                  <td>{item.queue_name ?? item.queue_url}</td><td>{item.approximate_number_of_messages}</td><td>{item.approximate_number_of_messages_not_visible}</td><td>{item.status ?? "ok"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
        {tab === "ecs" ? (
          <table>
            <thead><tr><th>Service</th><th>Status</th><th>Desired</th><th>Running</th><th>Pending</th><th>Launch</th></tr></thead>
            <tbody>
              {ecs?.ecs_services.map((service) => (
                <tr key={service.service_name}>
                  <td>{service.service_name}</td><td>{service.status}</td><td>{service.desired_count}</td><td>{service.running_count}</td><td>{service.pending_count}</td><td>{service.launch_type}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : null}
      </section>
    </section>
  );
}
