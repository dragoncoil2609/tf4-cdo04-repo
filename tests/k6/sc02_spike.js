// -----------------------------------------------------------------------------
// SC-02: Sudden Spike — payment-gw burst test
// TASK: CPOA-102 | CDO-W12-057 - Service Connect proxy cost/headroom check
//
// Uses constant-arrival-rate executor for true 4,500 RPS regardless of
// server response time. 2-minute duration keeps ADOT Collector buffer safe.
// Labels are low-cardinality (no random IDs) to avoid AMP cardinality explosions.
// -----------------------------------------------------------------------------

import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    spike_test: {
      executor: 'constant-arrival-rate',
      rate: 4500,
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: 100,
      maxVUs: 1000,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const endpoint = __ENV.TELEMETRY_API_HOST || 'localhost:8080';
  const baseUrl = /^https?:\/\//.test(endpoint)
    ? endpoint.replace(/\/$/, '')
    : `${__ENV.TELEMETRY_API_SCHEME || 'http'}://${endpoint.replace(/\/$/, '')}`;
  const url = `${baseUrl}/v1/ingest`;

  const payload = JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: 'tnt-benchmark',
    service_id: 'payment-gw',
    metric_type: 'api_latency_ms',
    value: Math.random() * 1000,
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
  };

  const res = http.post(url, payload, params);

  check(res, {
    'status is accepted': (r) => r.status === 201 || r.status === 202,
  });
}
