// -----------------------------------------------------------------------------
// SC-04: Noisy Baseline — fraud-detector sawtooth load test
//
// Sawtooth pattern 100 → 2,000 RPS (2 min ramp, 1 min hold, repeat) to create
// a noisy metric baseline. Tests that the anomaly detector does not false-alarm
// on legitimate cyclical variance while catching injected degradation.
//
// TelemetryPayload shape: ts, tenant_id, service_id, metric_type, value, labels
// Endpoint: POST /v1/ingest  (expected 201)
// Low-cardinality labels only — no random IDs.
// -----------------------------------------------------------------------------

import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const p99Latency = new Trend('kyc_p99_latency_ms', true);

export const options = {
  scenarios: {
    noisy_baseline: {
      executor: 'ramping-arrival-rate',
      startRate: 100,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 1500,
      stages: [
        // Sawtooth: ramp up 2 min → hold peak 1 min → drop → repeat
        { duration: '2m', target: 2000 },
        { duration: '1m', target: 2000 },
        { duration: '30s', target: 100 },
        { duration: '2m', target: 2000 },
        { duration: '1m', target: 2000 },
        { duration: '30s', target: 100 },
        { duration: '2m', target: 2000 },
        { duration: '1m', target: 2000 },
        { duration: '30s', target: 100 },
        { duration: '2m', target: 2000 },
        { duration: '1m', target: 2000 },
        { duration: '30s', target: 100 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(99)<800'],
  },
};

// Metric types centered on queue/worker health
const METRIC_TYPES = [
  'queue_depth',
  'api_latency_ms',
  'cpu_usage_percent',
  'memory_usage_percent',
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
    service_id: 'fraud-detector',
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
    tags: { scenario: 'sc04-noisy-baseline' },
  };

  const res = http.post(url, payload, params);
  p99Latency.add(res.timings.duration);

  check(res, {
    'status is 201 (accepted)': (r) => r.status === 201,
  });
}
