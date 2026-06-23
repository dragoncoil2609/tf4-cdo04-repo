# Test & Eval Report - Task force 4 · CDO Foresight Lens

<!-- Doc owner: Nhóm CDO-04 
     Status: DRAFT v1.3 - chờ review Tech Lead , số liệu thực tế sẽ điền sau khi chạy W12 -->

> **Lưu ý:** Bản này được định hình cấu trúc báo cáo dựa trên thiết kế kịch bản test hệ thống (`v1.3-SKELETON`, chưa chạy thật). Các giá trị "Measured/Achieved" còn để `<X>` sẽ được điền sau khi chạy thực tế SC-01 → SC-04 trong Tuần 12 (xem mục 6 - Timeline). Tên service/ARN đồng bộ theo `02_infra_design.md` Baseline v1.0 (AWS ECS Fargate, region `ap-southeast-1`).

---

## 0. Synthetic Test Scenarios (TF4 - Scenario Design cho W12 Build)

### 0.1 Bảng tổng hợp 4 scenario

| Scenario | Service mapping | Load profile | Mục tiêu mô phỏng |
|---|---|---|---|
| **SC-01 Gradual Drift** | `ledger-service` | Ramping-up 200 → 1,500 RPS trong 45 phút | Suy giảm hiệu năng dần do tăng tải tịnh tiến (p99 latency + Timestream ingestion) |
| **SC-02 Sudden Spike** | `payment-gateway` | Burst 200 → 4,500 RPS trong 30s, duy trì 5 phút | Đột biến tải tức thời (flash sale/DDoS-like), test scale-out + circuit breaker |
| **SC-03 Slow Leak** | `ledger-service` | Soak 800 RPS liên tục trong 2 tiếng | Memory/thread leak tích lũy dần, không giải phóng sau GC, dẫn tới OOM |
| **SC-04 Noisy Baseline & AI Down** | `kyc-worker` | Răng cưa 100 → 2,000 RPS liên tục, kèm inject AI API timeout | Queue backlog tăng do AI timeout/down, test Fallback Engine kích hoạt đúng ngưỡng |

### 0.2 Chi tiết từng scenario

**SC-01 - Gradual Drift (`ledger-service`)**

- **Expected Warning**: `WARN_LEDGER_DRIFT_DETECTED` - p99 latency và metric ingestion rate tăng tuyến tính +15% mỗi 10 phút, khớp pattern anomaly lịch sử.
- **Expected Recommendation**: "Phát hiện xu hướng trôi dạt hiệu năng tại `ledger-service`. Đề xuất scale-out task hoặc tối ưu batch size ghi Timestream trước khi vi phạm SLA (350ms) trong ~35 phút tới."
- **Metrics cần tạo**: `ledger_p99_latency_ms` (Histogram, k6 custom), `timestream_write_latency_ms` (Histogram, CloudWatch), `ledger_request_rate` (Counter).

**SC-02 - Sudden Spike (`payment-gateway`)**

- **Expected Warning**: `CRITICAL_PAYMENT_SPIKE_DETECTED` - throughput tăng từ 200 → 4,500 RPS trong < 30s, 5xx error rate vượt ngưỡng, scale-out đang được trigger.
- **Expected Recommendation**: "Hệ thống tự động scale-out `payment-gateway` qua Target Tracking. Nếu chi phí Task chạm ngưỡng Circuit Breaker (`[Target: $40 - TBD]`), tự động kích hoạt SNS Alert gọi Lambda hạ Desired Count. Khuyến nghị bật Rate Limiting ở mức `[Configurable: ~3,000 RPS]`."
- **Metrics cần tạo**: `payment_http_5xx_error_rate` (Rate), `http_req_duration` p99 (k6 built-in), `payment_gateway_running_task_count` (Gauge).

**SC-03 - Slow Leak (`ledger-service`)**

- **Expected Warning**: `WARN_LEDGER_RESOURCE_LEAK` - memory/thread count tăng liên tục không có plateau sau warm-up, dự báo OOM risk.
- **Expected Recommendation**: "Dự báo `ledger-service` OOM trong ~4.2 tiếng. Khuyến nghị rolling restart và heap dump phân tích. Nếu cost ingestion tiệm cận ngưỡng `[Target: $30 - TBD]`, tự động hạ sampling rate ghi metric từ 1s xuống 10s."
- **Metrics cần tạo**: `ledger_memory_utilization` (Gauge), `ledger_active_threads_count` (Gauge), `foresight_timestream_ingestion_cost_usd` (Derived metric).

**SC-04 - Noisy Baseline & AI Down (`kyc-worker`)**

- **Expected Warning**: `CRITICAL_QUEUE_BACKLOG_ANOMALY` - SQS backlog vượt baseline 320%, AI API timeout > 5,000ms phát hiện, message đang route xuống DLQ.
- **Expected Recommendation**: "Queue `kyc-worker` quá tải - Fallback Engine tự động kích hoạt: ngắt AI call, chuyển sang Static Rules, ghi Audit Decision trực tiếp vào Amazon DynamoDB để xả nghẽn và bảo vệ budget. Cần điều tra DLQ để replay sau khi AI hồi phục."
- **Metrics cần tạo**: `kyc_sqs_messages_visible` (Gauge), `kyc_sqs_dlq_messages_sent` (Counter), `kyc_ai_call_duration_ms` (Histogram), `kyc_fallback_activations_total` (Counter).

---

## 1. Test coverage

| Test type | Tool | Coverage / Scope |
|---|---|---|
| Unit test | pytest / go test | `<X%>` - chưa có số liệu, cần bổ sung từ CI report |
| Integration test | Custom k6 script + Postman | Luồng ghi metric (`ledger-service` → Amazon Timestream) + Luồng dự báo và xử lý bất đồng bộ (Amazon SQS → `kyc-worker` → AI/Fallback Engine → Amazon DynamoDB) |
| E2E test | k6 (4 scenario script, xem §3.5) | SC-01 Gradual Drift, SC-02 Sudden Spike, SC-04 Noisy Baseline & AI Down |
| Load test | k6 (`ramping-arrival-rate` executor) | Sustained 800-1,500 RPS (SC-01/03), burst 4,500 RPS (SC-02), peak target hệ thống 50,000 events/sec |
| Chaos test | Manual + k6 injected fault | 4 kịch bản: Gradual Drift, Sudden Spike, Slow Leak (memory), AI Down/Fallback |

---

## 2. SLO evidence

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| API availability | ≥ 99.5% | `<X%>` | 2 weeks build period | `<✓/✗>` |
| P99 latency (ledger-service / payment-gateway) | < 350ms (SLA cứng theo SC-01/02) | `<Xms>` | Rolling 60s trong test window | `<✓/✗>` |
| Error rate (5xx, SC-02 spike) | < 5% | `<X%>` | Rolling 30s tại peak | `<✓/✗>` |
| Budget / cost guard | < $200 / 2 tuần | `<X USD>` | 2-week build period | `<✓/✗>` |

### 2.1 SLO breach analysis

- Các ngưỡng cost (Circuit Breaker $40 cho SC-02, Sampling Throttle $30 cho SC-03) hiện là `[Hypothesis/TBD]`, cần calibrate lại sau Sandbox Run W12 trước khi dùng làm SLO chính thức.
- Nếu `ledger_p99_latency_ms` vượt 350ms liên tục ≥ 60s ở SC-01, root cause nghi vấn ưu tiên: Amazon Timestream write backpressure (ledger-service ghi metric vào Amazon Timestream) hoặc ECS Task CPU chạm ngưỡng 85%.

---

## 3. Load test results

### 3.1 Test setup

- **Load profile**: 4 kịch bản song song với peak target hệ thống 50,000 events/sec:
  - SC-01 Gradual Drift: ramp 200 → 1,500 RPS trong 45 phút
  - SC-02 Sudden Spike: burst 200 → 4,500 RPS trong 30s, duy trì 5 phút
  - SC-03 Slow Leak: soak 800 RPS liên tục trong 2 tiếng
  - SC-04 Noisy Baseline: răng cưa 100 → 2,000 RPS liên tục
- **Tenants/targets simulated**:
  - `ledger-service` (3 Tasks, 1 vCPU / 2 GB RAM)
  - `payment-gateway` (2 Tasks, 4 vCPU / 8 GB RAM)
  - `kyc-worker` (5 Tasks, 2 vCPU / 4 GB RAM)
- **Tool**: k6, executor `ramping-arrival-rate` (đã tối ưu hóa để kiểm soát RPS thực tế)

### 3.2 Results

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained (SC-01/03) | 800-1,500 | `<X>` |
| RPS burst peak (SC-02) | 4,500 trong 30s | `<X>` |
| P99 latency at peak | < 1,000ms (SC-02) / < 350ms (SC-01) | `<Xms>` |
| Error rate at peak | < 5% (SC-02) | `<X%>` |
| Auto-scale triggers (SC-02) | Scale-out ECS Task trong ≤ 2 phút | `<✓/✗>` |
| Circuit Breaker trigger | Ngắt đúng khi chạm `$40 - TBD` (SC-02) | `<✓/✗>` |

### 3.3 Bottleneck identified

> **Lưu ý:** Các mục dưới đây là nghi vấn chưa xác nhận, cần chạy thật để verify.

- **SC-01**: Độ trễ ghi (Write Latency) của Amazon Timestream tăng cao dưới áp lực backpressure khi `ledger-service` ghi lượng dữ liệu lớn.
- **SC-02**: Độ trễ mở rộng (Scale-out lag) của ECS Task tại lớp Internal ALB khi `payment-gateway` gặp tải burst.
- **SC-03**: Hiện tượng rò rỉ bộ nhớ (Memory leak) tại `ledger-service` không được giải phóng sau các chu kỳ Garbage Collection — dẫn tới nguy cơ sập container OOM dự kiến sau ~4.2 tiếng.
- **SC-04**: Lỗi timeout ứng dụng AI (>5,000ms) làm tắc nghẽn hàng đợi Amazon SQS, đẩy message xuống DLQ tại `kyc-worker`.

### 3.4 Infrastructure prerequisites (Đồng bộ Architecture Baseline v1.0)

| ECS Service | Task CPU / RAM | Task Count | Ghi chú |
|---|---|---|---|
| `ledger-service` | 1 vCPU / 2 GB RAM | 3 Tasks | ECS Auto-scaling **disabled** với SC-01, SC-03 |
| `payment-gateway` | 4 vCPU / 8 GB RAM | 2 Tasks | Rate limiter **disabled** tại ALB để đo raw capacity trong SC-02 |
| `kyc-worker` | 2 vCPU / 4 GB RAM | 5 Tasks | SQS visibility timeout = 30s; AI endpoint mock-timeout cho SC-04 |
| k6 Runner | 8 vCPU / 16 GB RAM | 1 EC2 riêng | Tách khỏi ECS Cluster để tránh rủi ro noisy neighbor |

### 3.5 Khung k6 Load Script Skeletons (Đạt tiêu chí: Sẵn sàng cho W12 Build)

#### SC-01 — Gradual Drift Configuration (ledger-service)

```javascript
import http from 'k6/http';
import { sleep, check } from 'k6';
import { Trend } from 'k6/metrics';

const p99Latency = new Trend('ledger_p99_latency_ms', true);

export const options = {
  stages: [
    { duration: '15m', target: 200  }, // Warm-up
    { duration: '20m', target: 1500 }, // Kéo tải lên 1,500 RPS để kích hoạt drift
    { duration: '10m', target: 0    }, // Cool-down
  ],
  thresholds: {
    'http_req_duration': ['p99<350'],
    'http_req_failed':   ['rate<0.01'],
  },
};

export default function () {
  const res = http.post(
    'http://internal-alb.staging.internal/v1/ledger/metrics',
    JSON.stringify({ tenant_id: 'tenant-001', value: Math.random() * 100 }),
    { headers: { 'Content-Type': 'application/json' }, tags: { scenario: 'SC-01' } }
  );
  p99Latency.add(res.timings.duration);
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
```

#### SC-02 — Sudden Spike Configuration (payment-gateway)

```javascript
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  summaryTimeUnit: 'ms',
  discardResponseBodies: true, // Chống tràn RAM trên k6 runner node khi chạy tải cao
  scenarios: {
    spike_attack: {
      executor: 'ramping-arrival-rate',
      startRate: 200,
      timeUnit: '1s',
      preAllocatedVUs: 1000,   // Cấp phát trước VU tránh độ trễ khởi tạo
      maxVUs: 5000,
      stages: [
        { duration: '30s', target: 4500 }, // Burst: 200 → 4,500 RPS trong 30s
        { duration: '5m',  target: 4500 }, // Duy trì tải peak trong 5 phút
        { duration: '30s', target: 200  }, // Hạ tải về baseline
      ],
    },
  },
  thresholds: {
    'http_req_failed':   ['rate<0.05'],
    'http_req_duration': ['p99<1000'],
  },
};

export default function () {
  const payload = JSON.stringify({ amount: 1000, currency: 'VND' });
  const params  = { headers: { 'Content-Type': 'application/json' }, tags: { scenario: 'SC-02' } };
  const res = http.post('http://internal-alb.staging.internal/v1/charge', payload, params);
  check(res, { 'status not 5xx': (r) => r.status < 500 });
}
```

### 3.6 Quy trình Reset & Khôi phục môi trường (Post-Test Cleanup)

Để loại bỏ triệt để hiện tượng nhiễm độc dữ liệu kiểm thử (Test Contamination), quy trình dọn dẹp bắt buộc phải chạy tự động sau mỗi scenario:

- **Clear Memory Leak (SC-03):** Thực hiện lệnh `kubectl rollout restart deployment/ledger-service -n staging` nhằm đưa bộ nhớ RAM của cụm container về trạng thái sạch ban đầu.
- **Purge Hàng đợi (SC-04):** Chạy lệnh `aws sqs purge-queue --queue-url $KYC_SQS_URL` và `aws sqs purge-queue --queue-url $KYC_DLQ_URL` nhằm xóa sạch tin nhắn tồn đọng trước khi chạy kịch bản tiếp theo.

---

## 4. Security test

### 4.1 Penetration touch points

- ☐ API auth bypass attempt (qua Internal ALB → `ledger-service` / `payment-gateway`)
- ☐ Cross-tenant data leak attempt
- ☐ SQL injection / NoSQL injection
- ☐ IAM privilege escalation (giữa ECS Task roles)
- ☐ Secret exposure via logs (`cost_interceptor.py`, env `COST_BREAKER_LIMIT`)

### 4.2 Vulnerability scan

- **Tool**: Trivy / Snyk / AWS Inspector `<chưa xác nhận tool chính thức>`
- **CRITICAL findings**: `<0 - cần xác nhận>`
- **HIGH findings**: `<≤ 3 với mitigation - cần xác nhận>`
- **Report**: `<repo>/security/scan-results.json`

---

## 5. Multi-tenant isolation test

| Test Method | Request Detail | Result |
|---|---|---|
| Tenant A reads Tenant B data via API | Inject token tenant A, request resource tenant B trên `ledger-service` | ❌ Should fail with 403 - `<chưa chạy>` |
| Cross-tenant queue contamination | Tenant A enqueue SQS với `tenant_id` của B (liên quan flow SC-04) | Audit log (DynamoDB) catches mismatch - `<chưa chạy>` |
| Timestream write isolation | Query Timestream record của tenant khác qua API trên `ledger-service` | Should return empty / error - `<chưa chạy>` |
| DB/DLQ row-level isolation | Inspect SQS DLQ messages của `kyc-worker` sau SC-04, kiểm tra `tenant_id` | Không lẫn dữ liệu giữa tenant - `<chưa chạy>` |

> **All tests must pass** - any leak = SEV1 incident.

---

## 6. Failure analysis

### 6.1 Failures encountered during 2-week build

| # | Failure | Root cause | Fix | Time to fix |
|---|---|---|---|---|
| 1 | k6 SC-02 dùng sai executor (`per-vu-iterations`) khiến RPS không kiểm soát đúng burst pattern | Executor không phù hợp mô phỏng spike theo RPS thực | Đổi sang `ramping-arrival-rate` với `preAllocatedVUs`/`maxVUs` | `<X giờ>` |
| 2 | `<chưa phát sinh - sẽ cập nhật trong W12>` | ... | ... | `<X giờ>` |

### 6.2 Test gaps acknowledged

- **Gap 1**: Toàn bộ 4 scenario (SC-01 → SC-04) hiện mới ở dạng skeleton/draft, chưa chạy thật trên Staging - số liệu Measured/Achieved trong báo cáo này còn placeholder, sẽ điền sau W12 Day 5.
- **Gap 2**: Ngưỡng cost ($40 Circuit Breaker SC-02, $30 Sampling Throttle SC-03, $0.00005/exec) là giả định `[Hypothesis/TBD]`, cần calibrate lại theo AWS Pricing thực tế sau Sandbox Run.
- **Gap 3**: Penetration test và vulnerability scan (mục 4) chưa có lịch chạy cụ thể, cần xác nhận tool và schedule với Security team.
- **Gap 4**: Multi-tenant isolation test (mục 5) chưa chạy - đây là rủi ro cao nhất vì leak = SEV1, cần ưu tiên trước capstone.

---

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - SLO targets và Architecture Baseline v1.0 validated trong §3 doc này
- [`03_security_design.md`](03_security_design.md) §14 - Risk registry mitigated bởi test results §6 doc này
- [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - Joint eval: AI engine quality (Fallback Engine SC-04) + CDO infra integration
