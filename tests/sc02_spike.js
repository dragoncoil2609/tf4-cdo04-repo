import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// Cấu hình linh hoạt Endpoint qua biến môi trường (Mặc định gọi qua HTTP theo quy chuẩn Sandbox)
const TARGET_URL = __ENV.TARGET_URL || 'http://tf4-cdo04-alb-123456789.us-east-1.elb.amazonaws.com';
const INGEST_URL = `${TARGET_URL.replace(/\/$/, '')}/v1/ingest`;
const TENANT_ID = __ENV.TENANT_ID || 'tnt-sc02-spike';
const REGION = 'us-east-1';

// Khởi tạo các Custom Trends giám sát ma trận tải nâng cao
const trendSpikeLatency = new Trend('sc02_spike_latency_ms', true);
const trendEcsProcessingTime = new Trend('sc02_ecs_processing_ms', true);
const rateSpikeErrors = new Rate('sc02_spike_error_rate');
const counterSpikeRequests = new Counter('sc02_spike_requests');

export const options = {
  discardResponseBodies: true,
  scenarios: {
    spike_scenario: {
      executor: 'ramping-arrival-rate', // Khởi chạy executor điều khiển RPS chủ động
      startRate: 5,                     // Baseline: 5 RPS
      timeUnit: '1s',
      preAllocatedVUs: 20,              // Khởi tạo sẵn vùng đệm VUs để sẵn sàng tăng tốc
      maxVUs: 400,                      // [COST GUARD]: Ngưỡng chặn trên bảo vệ tài nguyên máy local không bị treo

      stages: [
        { duration: '30s', target: 5 },   // 1. Duy trì Baseline 5 RPS trong 30s
        { duration: '15s', target: 200 }, // 2. Sudden Spike surge: Vọt từ 5 -> 200 RPS trong 15s
        { duration: '1m', target: 200 },  // 3. Burst Control: Giữ đỉnh 200 RPS trong flat 1 phút
        { duration: '15s', target: 5 },   // 4. Dropdown: Giảm đột ngột về lại 5 RPS trong 15s
        { duration: '30s', target: 5 },   // 5. Recovery: Theo dõi hệ thống hồi phục sau tải trong 30s
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(99)<200'],      // SLA quy định khắt khe dưới 200ms
    http_req_failed: ['rate<0.05'],        // Ngưỡng lỗi cho phép trong điều kiện DDoS burst < 5%
    sc02_spike_latency_ms: ['p(99)<200'],
  },
  tags: { scenario: 'SC-02', service: 'payment-gateway', region: REGION },
};

function buildHeaders() {
  return {
    'Content-Type': 'application/json',
    'X-Tenant-Id': TENANT_ID,
    'X-AMP-Signaling': 'spike-burst-test',
  };
}

function buildSpikePayload() {
  const burstLoad = 2000 + Math.floor(Math.random() * 8000);
  return JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: TENANT_ID,
    service_id: 'payment-gateway',
    metric_type: Math.random() > 0.5 ? 'active_connections' : 'api_latency_ms',
    value: Math.random() > 0.5 ? burstLoad : Number((250 + Math.random() * 750).toFixed(2)),
    labels: {
      region: REGION,
      scenario: 'SC-02',
      endpoint: '/checkout',
      env: 'sandbox'
    },
  });
}

export default function () {
  const payload = buildSpikePayload();

  counterSpikeRequests.add(1);

  const res = http.post(INGEST_URL, payload, {
    headers: buildHeaders(),
    tags: { scenario: 'SC-02', service: 'payment-gateway' },
  });

  // Ghi nhận chỉ số Latency vào hệ thống đo đạc
  trendSpikeLatency.add(res.timings.duration);
  rateSpikeErrors.add(res.status >= 500 || res.status === 0);

  // Giả lập bóc tách chỉ số xử lý của ECS Task từ Header phản hồi của ALB (nếu có)
  const ecsTime = res.headers['X-ECS-Processing-Time-Ms'];
  if (ecsTime) {
    trendEcsProcessingTime.add(parseFloat(ecsTime));
  }

  // Kiểm tra tính toàn vẹn và khả năng sống sót của Mạch ngắt (Circuit-Breaker)
  check(res, {
    'ALB Target Group Reachable (not 0)': (r) => r.status !== 0,
    'Payment Gateway Active Response': (r) => r.status === 200 || r.status === 202 || r.status === 429, // Chấp nhận cả 429 Rate Limit
  });
}