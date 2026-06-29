import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

// Cấu hình linh hoạt mục tiêu kiểm thử qua biến môi trường hoặc chạy mock local
const INGEST_URL = __ENV.TARGET_URL || 'http://localhost:8080/v1/ingest';
const TENANT_ID = __ENV.TENANT_ID || 'tnt-sc01-drift';
const REGION = 'us-east-1';

// CPOA-88: Khởi tạo các Custom Trends để đo đạc ma trận Telemetry Contract
const trendApiLatency = new Trend('api_latency_ms', true);
const trendCpuUsage = new Trend('cpu_usage_percent', true);
const trendDbPool = new Trend('db_connection_pool_pct', true);

export const options = {
  // Cấu hình Ramping VUs Tuần 12: Tăng dần từ 1 -> 50 VUs để kích hoạt data drift
  stages: [
    { duration: '2m', target: 50 },
    { duration: '3m', target: 50 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(99)<200'],
    http_req_failed: ['rate<0.01'],
    api_latency_ms: ['p(99)<200'],
  },
  tags: { scenario: 'SC-01', service: 'ledger-service', region: REGION },
};

function buildHeaders() {
  return {
    'Content-Type': 'application/json',
    'X-Tenant-Id': TENANT_ID,
    'X-AMP-Signaling': 'active-sample' // Đánh dấu sample đẩy về cụm Prometheus AMP
  };
}

function buildTelemetryPayload(iter) {
  // Giả lập giá trị tăng dần theo số vòng lặp (Iteration) để tạo hiệu ứng rò rỉ tải/drift hệ thống
  const driftFactor = 1 + (iter % 150) / 100;
  
  const currentApiLatency = Number((45 * driftFactor + (iter % 10)).toFixed(2));
  const currentCpuUsage = Number((35 * driftFactor + (iter % 5)).toFixed(2));
  const currentDbPool = Number((20 * driftFactor + (iter % 8)).toFixed(2));

  return {
    payload: JSON.stringify({
      ts: new Date().toISOString(),
      tenant_id: TENANT_ID,
      service_id: 'ledger-service',
      region: REGION,
      metrics: {
        api_latency_ms: currentApiLatency,
        cpu_usage_percent: currentCpuUsage,
        db_connection_pool_pct: currentDbPool
      },
      // AMP sample data structure alignment
      prometheus_samples: [
        { metric_name: 'ledger_api_duration_seconds', value: currentApiLatency / 1000 },
        { metric_name: 'ledger_cpu_utilization', value: currentCpuUsage }
      ]
    }),
    metrics: { currentApiLatency, currentCpuUsage, currentDbPool }
  };
}

export default function () {
  const { payload, metrics } = buildTelemetryPayload(__ITER);

  // Ghi nhận số liệu cục bộ vào Custom Trend trước khi bắn
  trendApiLatency.add(metrics.currentApiLatency);
  trendCpuUsage.add(metrics.currentCpuUsage);
  trendDbPool.add(metrics.currentDbPool);

  // Thực hiện cuộc gọi POST /v1/ingest
  const res = http.post(INGEST_URL, payload, { headers: buildHeaders() });

  // Kiểm tra trạng thái phản hồi từ hệ thống
  check(res, {
    'POST /v1/ingest accepted (2xx)': (r) => r.status >= 200 && r.status < 300,
    'AMP remote-write stream valid': (r) => r.status === 202 || r.status === 200,
  });

  sleep(0.1);
}