// Low-RPS acceptance load for Telemetry API ingest.
// Emits all 7 contracted AI signals; proves steady ingest health, not stress ceiling.
//
// Authentication:
//   When AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables are
//   present, uses k6 jslib AWS SignatureV4 with service execute-api.  The
//   signed request carries X-Tenant-Ingest-Token (no Authorization header).
//   Falls back to Authorization: Bearer <TENANT_INGEST_TOKEN> when AWS
//   credentials are absent (local / non-AWS runtime).
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { AWSConfig, SignatureV4, Endpoint } from 'https://jslib.k6.io/aws/0.14.0/signature.js';

const RATE = Number(__ENV.RATE || 50);
const DURATION = __ENV.DURATION || '10m';
const TENANT_ID = __ENV.TENANT_ID || 'demo-tenant-001';
const TENANT_INGEST_TOKEN = __ENV.TENANT_INGEST_TOKEN || '';
const AWS_REGION = __ENV.AWS_REGION || 'us-east-1';
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

// Decide at init-time whether to use SigV4.
const HAS_AWS_CREDS = !!(__ENV.AWS_ACCESS_KEY_ID && __ENV.AWS_SECRET_ACCESS_KEY);
let signer = null;
if (HAS_AWS_CREDS) {
  const config = new AWSConfig({
    region: AWS_REGION,
    accessKeyId: __ENV.AWS_ACCESS_KEY_ID,
    secretAccessKey: __ENV.AWS_SECRET_ACCESS_KEY,
    sessionToken: __ENV.AWS_SESSION_TOKEN,
  });
  signer = new SignatureV4({
    service: 'execute-api',
    region: config.region,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
      sessionToken: config.sessionToken,
    },
    uriEscapePath: false,
    applyChecksum: true,
  });
}

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

  let url = `${BASE_URL}/v1/ingest`;
  let headers = {
    'Content-Type': 'application/json',
    'X-Tenant-Id': TENANT_ID,
  };
  let body = payload;

  if (signer) {
    // SigV4 path: sign the entire request.  The tenant token is passed through
    // a dedicated header rather than the Authorization field.
    if (TENANT_INGEST_TOKEN) {
      headers['X-Tenant-Ingest-Token'] = TENANT_INGEST_TOKEN;
    }
    const signed = signer.sign({
      method: 'POST',
      path: '/v1/ingest',
      headers: headers,
      body: payload,
      endpoint: new Endpoint(BASE_URL),
    });
    url = signed.url;
    headers = signed.headers;
    body = signed.body || payload;
  } else if (TENANT_INGEST_TOKEN) {
    // Bearer token path (local / non-AWS runtime).
    headers.Authorization = `Bearer ${TENANT_INGEST_TOKEN}`;
  }

  const res = http.post(url, body, {
    headers,
    tags: { scenario: 'acceptance', service_id: serviceId },
  });

  check(res, {
    'status is accepted': (r) => r.status === 201 || r.status === 202,
  });
}
