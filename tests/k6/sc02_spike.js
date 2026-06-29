// -----------------------------------------------------------------------------
// TASK: CPOA-102 | CDO-W12-057 - Service Connect proxy cost/headroom check
// OWNER: Tạ Hoàng Huy
//
// RATIONALE (LÝ DO THIẾT KẾ CODE):
// 1. Sử dụng executor 'constant-arrival-rate' thay vì 'shared-iterations' truyền thống.
//    Điều này giúp k6 giữ tốc độ bắn tải cố định ở đúng 4,500 RPS (rate = 4500) bất kể
//    phản hồi từ server nhanh hay chậm, phản ánh đúng tải spike mong muốn.
// 2. Thiết lập 'duration: 2m' (chạy ngắn trong 2 phút) để tránh việc duy trì tải cực lớn
//    quá lâu gây tràn bộ nhớ đệm (buffer overflow) của ADOT Collector, làm ảnh hưởng đến
//    hệ thống Prometheus (AMP) thật.
// 3. Payload giả lập chứa nhãn tĩnh ('labels' sạch, không có request_id, user_id sinh ngẫu nhiên)
//    nhằm tránh nguy cơ làm bùng nổ cardinality nhãn trên Amazon Managed Prometheus (AMP),
//    giảm tải cho CPU của Telemetry API khỏi việc chạy logic filter denylist ở Task 101.
// -----------------------------------------------------------------------------

import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    spike_test: {
      executor: 'constant-arrival-rate',
      rate: 4500,                  // Mục tiêu tải spike đạt chính xác 4,500 RPS
      timeUnit: '1s',              // Tần suất đo trên mỗi giây
      duration: '2m',              // Chạy giới hạn trong 2 phút để bảo vệ hệ thống
      preAllocatedVUs: 100,        // Khởi tạo sẵn 100 Virtual Users để tránh trễ lúc bắt đầu
      maxVUs: 1000,                // Cho phép co giãn tối đa 1000 VUs nếu server phản hồi chậm
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],    // Chấp nhận tỉ lệ lỗi request tối đa 1% dưới tải spike
    http_req_duration: ['p(95)<500'],  // 95% số request phải hoàn thành dưới 500ms
  },
};

export default function () {
  // Thêm fallback an toàn đề phòng quên truyền biến môi trường
  const host = __ENV.TELEMETRY_API_HOST || 'localhost:8080';
  const url = `http://${host}/v1/telemetry`;
  
  // Dữ liệu giả lập sạch sẽ, định dạng chuẩn JSON theo Telemetry Contract
  const payload = JSON.stringify({
    ts: new Date().toISOString(),
    tenant_id: 'tnt-benchmark',
    service_id: 'payment-gateway',
    metric_type: 'cpu_usage_percent',
    value: 45.5,
    labels: {
      region: 'us-east-1',
      environment: 'staging'
    }
  });

  const params = {
    headers: {
      'Content-Type': 'application/json',
      'X-Tenant-Id': 'tnt-benchmark'
    },
  };

  const res = http.post(url, payload, params);
  
  // Kiểm tra HTTP Status 202 Accepted từ Telemetry API
  check(res, {
    'status is 202': (r) => r.status === 202,
  });
}
