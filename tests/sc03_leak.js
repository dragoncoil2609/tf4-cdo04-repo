import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

// Đọc URL động từ môi trường - hạ cấp xuống HTTP cho Sandbox
const TARGET_URL = __ENV.TARGET_URL || 'http://tf4-cdo04-alb-123456789.us-east-1.elb.amazonaws.com';
const INGEST_URL = `${TARGET_URL.replace(/\/$/, '')}/v1/ingest`;
const TENANT_ID = __ENV.TENANT_ID || 'tnt-sc03-leak';
const REGION = 'us-east-1';

// Khởi tạo các Custom Trends đo đạc cục bộ
const soakLatency = new Trend('sc03_soak_latency_ms', true);
const memorySignal = new Trend('sc03_memory_signal_pct', true);

// Thời gian bắt đầu chạy test để tính toán thời gian trôi qua (elapsed time)
const startTime = Date.now();

export const options = {
  scenarios: {
    soak_scenario: {
      executor: 'constant-vus',
      vus: 80,                 // Cố định 80 Virtual Users ngâm tải liên tục
      duration: '5m',          // Flat 5 phút đúng yêu cầu Tuần 12
    },
  },
  thresholds: {
    http_req_duration: ['p(99)<200'],
    http_req_failed: ['rate<0.01'],
    sc03_soak_latency_ms: ['p(99)<200'],
  },
  tags: { scenario: 'SC-03', service: 'ledger-service', region: REGION },
};

function buildHeaders() {
  return {
    'Content-Type': 'application/json',
    'X-Tenant-Id': TENANT_ID,
    'X-AMP-Signaling': 'soak-leak-detection'
  };
}

function buildSoakPayload(elapsedSeconds) {
  // Mô phỏng bộ nhớ tăng dần từ 45% -> chạm trần 98% nếu ngâm quá lâu
  const memoryPct = Math.min(98, 45 + elapsedSeconds * 0.18);
  const apiLatency = Number((180 + elapsedSeconds * 0.25).toFixed(2));

  return JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: TENANT_ID,
    service_id: 'ledger-service',
    metric_type: 'memory_usage_percent',
    value: Number(memoryPct.toFixed(2)),
    labels: {
      region: REGION,
      scenario: 'SC-03',
      env: 'sandbox',
      soak_elapsed_s: String(Math.floor(elapsedSeconds)),
    },
    // Chèn kèm ma trận ma sát Telemetry Contract để AMP bắt trọn gói
    companion_metrics: [
      { metric_type: 'cpu_usage_percent', value: Number((60 + elapsedSeconds * 0.05).toFixed(2)) },
      { metric_type: 'api_latency_ms', value: apiLatency }
    ],
    // Cấu trúc Prometheus samples map thẳng sang AMP Workspace
    prometheus_samples: [
      { metric_name: 'container_memory_usage_percent', value: memoryPct },
      { metric_name: 'container_api_latency_ms', value: apiLatency }
    ]
  });
}

export default function () {
  const elapsedSeconds = (Date.now() - startTime) / 1000;
  const body = buildSoakPayload(elapsedSeconds);

  // Ghi nhận số liệu cục bộ
  memorySignal.add(JSON.parse(body).value);

  const res = http.post(INGEST_URL, body, {
    headers: buildHeaders(),
    tags: { scenario: 'SC-03', service: 'ledger-service' },
  });

  soakLatency.add(res.timings.duration);

  check(res, {
    'SC-03 Ingest Accepted (2xx)': (r) => r.status >= 200 && r.status < 300,
    'SC-03 Host Healthy': (r) => r.status !== 0,
  });

  sleep(0.05); // Tần suất đẩy request cao để ép luồng bộ nhớ
}