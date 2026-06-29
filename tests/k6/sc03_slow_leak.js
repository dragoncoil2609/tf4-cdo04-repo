// -----------------------------------------------------------------------------
// SC-03: Slow Leak — ledger soak test
//
// Sustained 800 RPS for 2 hours to detect memory/thread leaks that accumulate
// gradually without GC recovery. Uses constant-arrival-rate for steady load.
//
// TelemetryPayload shape: ts, tenant_id, service_id, metric_type, value, labels
// Endpoint: POST /v1/ingest  (expected 201)
// Low-cardinality labels only — no random IDs.
// -----------------------------------------------------------------------------

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const p99Latency = new Trend('leak_p99_latency_ms', true);

export const options = {
  scenarios: {
    slow_leak: {
      executor: 'constant-arrival-rate',
      rate: 800,
      timeUnit: '1s',
      duration: '2h',
      preAllocatedVUs: 50,
      maxVUs: 500,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(99)<500'],
  },
};

// Metric types centered on memory/resource leak indicators
const METRIC_TYPES = [
  'memory_usage_percent',
  'cpu_usage_percent',
  'api_latency_ms',
  'active_connections',
];

let _metricIdx = 0;

export default function () {
  const host = __ENV.TELEMETRY_API_HOST || 'localhost:8080';
  const url = `http://${host}/v1/ingest`;

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
    tags: { scenario: 'sc03-slow-leak' },
  };

  const res = http.post(url, payload, params);
  p99Latency.add(res.timings.duration);

  check(res, {
    'status is 201 (accepted)': (r) => r.status === 201,
  });
}
