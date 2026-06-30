// -----------------------------------------------------------------------------
// SC-01: Gradual Drift — ledger ramping load test
//
// Simulates gradual performance degradation via linearly increasing RPS.
// Warm-up 200 RPS (15 min) → ramp to 1,500 RPS (20 min) → cool-down (10 min).
// Detects drift in p99 latency, CPU and DB connection pool pressure.
//
// TelemetryPayload shape: ts, tenant_id, service_id, metric_type, value, labels
// Endpoint: POST /v1/ingest  (expected 201/202)
// Low-cardinality labels only — no request_id/user_id.
// -----------------------------------------------------------------------------

import http from 'k6/http';
import { sleep, check } from 'k6';
import { Trend } from 'k6/metrics';

const p99Latency = new Trend('ledger_p99_latency_ms', true);

export const options = {
  stages: [
    { duration: '15m', target: 200 },
    { duration: '20m', target: 1500 },
    { duration: '10m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(99)<350'],
    http_req_failed: ['rate<0.01'],
  },
};

// Metric types cycled to simulate real multi-metric telemetry
const METRIC_TYPES = [
  'api_latency_ms',
  'cpu_usage_percent',
  'memory_usage_percent',
  'db_connection_pool_pct',
];

let _metricIdx = 0;

export default function () {
  const endpoint = __ENV.TELEMETRY_API_HOST || 'localhost:8080';
  const baseUrl = /^https?:\/\//.test(endpoint)
    ? endpoint.replace(/\/$/, '')
    : `${__ENV.TELEMETRY_API_SCHEME || 'http'}://${endpoint.replace(/\/$/, '')}`;
  const url = `${baseUrl}/v1/ingest`;

  const metricType = METRIC_TYPES[_metricIdx % METRIC_TYPES.length];
  _metricIdx++;

  const payload = JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: 'tnt-benchmark',
    service_id: 'ledger',
    metric_type: metricType,
    value: Math.random() * 100,
    labels: {
      region: 'us-east-1',
      environment: 'staging',
    },
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Tenant-Id': 'tnt-benchmark',
    },
    tags: { scenario: 'sc01-gradual-drift' },
  };

  const res = http.post(url, payload, params);
  p99Latency.add(res.timings.duration);

  check(res, {
    'status is accepted': (r) => r.status === 201 || r.status === 202,
  });

  sleep(1);
}
