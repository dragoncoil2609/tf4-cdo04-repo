import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

// Đọc Endpoint động từ môi trường - Cấu hình cổng HTTP Sandbox tiêu chuẩn
const TARGET_URL = __ENV.TARGET_URL || 'http://tf4-cdo04-alb-123456789.us-east-1.elb.amazonaws.com';
const INGEST_URL = `${TARGET_URL.replace(/\/$/, '')}/v1/ingest`;
const TENANT_ID = __ENV.TENANT_ID || 'tnt-sc04-ai-down';
const REGION = 'us-east-1';

const poisonAttempts = new Counter('sc04_poison_attempts');
const ingestRejections = new Rate('sc04_ingest_rejection_rate');
const aiFailureHooks = new Counter('sc04_ai_failure_hooks');

export const options = {
  discardResponseBodies: true,
  scenarios: {
    poison_scenario: {
      executor: 'constant-vus',
      vus: 20,          // Kịch bản cố định 20 VUs
      duration: '2m',   // Thời gian burst liên tục trong 2 phút
    },
  },
  thresholds: {
    http_req_duration: ['p(99)<200'],
    http_req_failed: ['rate<0.50'], // Cho phép rate fail cao vì chủ động inject 4xx ở lớp Ingest
  },
  tags: { scenario: 'SC-04', service: 'kyc-worker', region: REGION },
};

const POISON_VARIANTS = [
  {
    name: 'malformed-json-body',
    build: () => ({
      body: '{"tenant_id":"tnt-sc04","service_id":"kyc-worker","metric_type":"queue_depth","value":',
      headers: { 'Content-Type': 'application/json', 'X-Tenant-Id': TENANT_ID },
    }),
  },
  {
    name: 'missing-tenant-id',
    build: () => ({
      body: JSON.stringify({
        ts: new Date().toISOString(),
        service_id: 'kyc-worker',
        metric_type: 'queue_depth',
        value: 15000,
        labels: { region: REGION, queue_name: 'kyc-events-sqs' },
      }),
      headers: { 'Content-Type': 'application/json', 'X-Tenant-Id': TENANT_ID },
    }),
  },
  {
    name: 'ai-engine-5xx-hook',
    build: () => ({
      body: JSON.stringify({
        ts: new Date().toISOString(),
        tenant_id: TENANT_ID,
        service_id: 'kyc-worker',
        metric_type: 'queue_depth',
        value: 50000,
        labels: { region: REGION, queue_name: 'kyc-events-sqs', scenario: 'SC-04' },
        _test_inject: { force_ai_status: 503, force_ai_timeout_ms: 5000, poison_pill: true },
      }),
      headers: {
        'Content-Type': 'application/json',
        'X-Tenant-Id': TENANT_ID,
        'X-Force-AI-Error': '503',
        'X-Simulate-AI-Timeout': 'true',
      },
    }),
  },
];

export default function () {
  const variant = POISON_VARIANTS[__ITER % POISON_VARIANTS.length];
  const { body, headers } = variant.build();

  poisonAttempts.add(1);
  if (variant.name === 'ai-engine-5xx-hook') {
    aiFailureHooks.add(1);
  }

  const res = http.post(INGEST_URL, body, {
    headers,
    tags: { scenario: 'SC-04', service: 'kyc-worker', poison: variant.name },
  });

  const rejected = res.status >= 400;
  ingestRejections.add(rejected);

  check(res, {
    'SC-04 Ingest Responded': (r) => r.status !== 0,
    'SC-04 Gate Validation Active': (r) => 
      variant.name.includes('malformed') || variant.name.includes('missing') 
        ? r.status === 400 
        : r.status === 202 || r.status === 200,
  });

  sleep(0.1);
}