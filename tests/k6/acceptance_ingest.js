// Low-RPS acceptance load for Telemetry API ingest.
// Emits all 7 contracted AI signals; proves steady ingest health, not stress ceiling.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const RATE = Number(__ENV.RATE || 50);
const DURATION = __ENV.DURATION || '10m';
const TENANT_ID = __ENV.TENANT_ID || 'demo-tenant-001';
const TENANT_INGEST_TOKEN = __ENV.TENANT_INGEST_TOKEN || '';
const SERVICE_IDS = (__ENV.SERVICE_IDS || __ENV.SERVICE_ID || 'ledger,payment-gw,fraud-detector')
  .split(',')
  .map((serviceId) => serviceId.trim())
  .filter(Boolean);
const ENDPOINT = __ENV.TELEMETRY_API_HOST || 'localhost:8080';
const BASE_URL = /^https?:\/\//.test(ENDPOINT)
  ? ENDPOINT.replace(/\/$/, '')
  : `${__ENV.TELEMETRY_API_SCHEME || 'http'}://${ENDPOINT.replace(/\/$/, '')}`;

const METRICS = [
  ['cpu_usage_percent', 42, { region: 'us-east-1', environment: 'acceptance' }],
  ['memory_usage_percent', 55, { region: 'us-east-1', environment: 'acceptance' }],
  ['active_connections', 120, { region: 'us-east-1', environment: 'acceptance' }],
  ['db_connection_pool_pct', 35, { region: 'us-east-1', db_type: 'postgres', environment: 'acceptance' }],
  ['queue_depth', 3, { region: 'us-east-1', queue_name: 'acceptance', environment: 'acceptance' }],
  ['cache_hit_rate_pct', 91, { region: 'us-east-1', cache_type: 'redis', environment: 'acceptance' }],
  ['api_latency_ms', 180, { region: 'us-east-1', environment: 'acceptance' }],
];

export const options = {
  scenarios: {
    acceptance_ingest: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(50, RATE),
      maxVUs: Math.max(100, RATE * 2),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
    dropped_iterations: ['count<1'],
  },
};

export default function () {
  const sequence = exec.scenario.iterationInTest;
  const metric = METRICS[sequence % METRICS.length];
  const serviceId = SERVICE_IDS[sequence % SERVICE_IDS.length];
  const payload = JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: TENANT_ID,
    service_id: serviceId,
    metric_type: metric[0],
    value: metric[1],
    labels: metric[2],
  });

  const headers = {
    'Content-Type': 'application/json',
    'X-Tenant-Id': TENANT_ID,
  };
  if (TENANT_INGEST_TOKEN) {
    headers.Authorization = `Bearer ${TENANT_INGEST_TOKEN}`;
  }

  const res = http.post(`${BASE_URL}/v1/ingest`, payload, {
    headers,
    tags: { scenario: 'acceptance', service_id: serviceId },
  });

  check(res, {
    'status is accepted': (r) => r.status === 201 || r.status === 202,
  });
}
