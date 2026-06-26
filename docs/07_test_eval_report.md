# Test & Eval Report - Task force 4 · CDO Foresight Lens

<!-- Doc owner: Nhóm CDO / QA Lead
     Status: DRAFT v1.3 - chờ review Tech Lead (anh An), số liệu thực tế sẽ điền sau khi chạy W12 -->

> **Lưu ý (DRAFT):** Bản này định hình cấu trúc báo cáo dựa trên thiết kế kịch bản test (`v1.3-SKELETON`). **Toàn bộ nội dung chưa được chạy thật** — các phân tích bottleneck, expected warning, và recommendation hiện là giả định thiết kế, chưa phải kết quả thực tế. Các giá trị "Measured/Achieved" còn để `<X>` sẽ được điền sau khi chạy thực tế SC-01 → SC-04 trong Tuần 12 (xem mục 6 - Timeline). Tên service/ARN đồng bộ theo `02_infra_design.md` Baseline v1.0 (AWS ECS Fargate, region `us-east-1`).

---

## 0. Synthetic Test Scenarios (TF4 - Scenario Design cho W12 Build)

> **Lưu ý :** `ledger-service`, `payment-gateway`, `kyc-worker` là mock monitored services dùng cho synthetic scenarios — khác với CDO platform workloads thực tế là Telemetry API, Prediction Worker và AI Engine. Compute/k6 runner cho các mock service là test-window-only và không nằm trong full-month platform baseline cost.

### 0.1 Bảng tổng hợp 4 scenario

| Scenario | Service mapping | Load profile | Mục tiêu mô phỏng |
|---|---|---|---|
| **SC-01 Gradual Drift** | `ledger-service` | Ramping-up 200 → 1,500 RPS trong 45 phút | Suy giảm hiệu năng dần do tăng tải tịnh tiến (p99 latency + AMP remote-write ingestion) |
| **SC-02 Sudden Spike** | `payment-gateway` | Burst 200 → 4,500 RPS trong 30s, duy trì 5 phút | Đột biến tải tức thời (flash sale/DDoS-like), test scale-out + circuit breaker |
| **SC-03 Slow Leak** | `ledger-service` | Soak 800 RPS liên tục trong 2 tiếng | Memory/thread leak tích lũy dần, không giải phóng sau GC, dẫn tới OOM |
| **SC-04 Noisy Baseline & AI Down** | `kyc-worker` | Răng cưa 100 → 2,000 RPS liên tục, kèm inject AI API timeout | Queue backlog tăng do AI timeout/down, test Fallback Engine kích hoạt đúng ngưỡng |

### 0.2 Chi tiết từng scenario

Tất cả scenario phải tạo hoặc forward thành các signal đúng AI Telemetry Contract trước khi đưa vào `signal_window`: `cpu_usage_percent`, `memory_usage_percent`, `active_connections`, `db_connection_pool_pct`, `queue_depth`, `cache_hit_rate_pct`, `api_latency_ms`. Các metric phụ như `error_rate` hoặc `oldest_message_age_seconds` chỉ dùng cho dashboard/fallback nội bộ.

Baseline mới dùng AMP tại `us-east-1`; test phải chứng minh telemetry vào AMP qua `remote_write`, Prediction Worker query được PromQL `query_range` đủ 120 phút, và AI request vẫn giữ schema contract. Demo acceptance không tự động chứng minh 50k events/sec production ceiling; ceiling đó cần load test riêng với bounded samples/event và label cardinality.

**SC-01 - Gradual Drift (`ledger-service`)**

- **Expected Warning**: `WARN_LEDGER_DRIFT_DETECTED` - `api_latency_ms`, `cpu_usage_percent` và `db_connection_pool_pct` tăng tuyến tính +15% mỗi 10 phút, khớp pattern anomaly lịch sử.
- **Expected Recommendation**: "Phát hiện xu hướng trôi dạt hiệu năng tại `ledger-service`. Đề xuất scale-out task hoặc tối ưu batch/query trước khi AI SLO p99 500ms/platform p99 800ms bị vi phạm trong ~35 phút tới."
- **Metrics cần tạo/forward**: `api_latency_ms`, `cpu_usage_percent`, `memory_usage_percent`, `db_connection_pool_pct`; dashboard phụ có thể đo `amp_remote_write_latency_ms`.

**SC-02 - Sudden Spike (`payment-gateway`)**

- **Expected Warning**: `CRITICAL_PAYMENT_SPIKE_DETECTED` - `active_connections` và `api_latency_ms` tăng nhanh, 5xx nội bộ vượt ngưỡng fallback, scale-out đang được trigger.
- **Expected Recommendation**: "Hệ thống tự động scale-out `payment-gateway` qua Target Tracking. Nếu budget alarm tiệm cận 90-100%, pause synthetic load test thay vì tắt audit/fallback. Khuyến nghị bật rate limiting ứng dụng theo quota demo."
- **Metrics cần tạo/forward**: `active_connections`, `api_latency_ms`, `cpu_usage_percent`, `memory_usage_percent`; `error_rate` chỉ dùng fallback/dashboard.

**SC-03 - Slow Leak (`ledger-service`)**

- **Expected Warning**: `WARN_LEDGER_RESOURCE_LEAK` - `memory_usage_percent` và `api_latency_ms` tăng liên tục không có plateau sau warm-up, dự báo OOM risk.
- **Expected Recommendation**: "Dự báo `ledger-service` OOM trong ~4.2 tiếng. Khuyến nghị rolling restart và heap dump phân tích; nếu budget gần ngưỡng, giảm synthetic load/log verbosity, không giảm prediction cadence dưới 5 phút."
- **Metrics cần tạo/forward**: `memory_usage_percent`, `cpu_usage_percent`, `api_latency_ms`, `active_connections`.

**SC-04 - Noisy Baseline & AI Down (`kyc-worker`)**

- **Expected Warning**: `CRITICAL_QUEUE_BACKLOG_ANOMALY` - `queue_depth` vượt baseline, AI `/v1/predict` timeout hoặc trả 5xx/503, Worker kích hoạt static threshold fallback.
- **Expected Recommendation**: "Queue `kyc-worker` quá tải - Worker chuyển sang Static Rules, ghi Audit Decision vào DynamoDB và không delete SQS job trước khi audit write thành công. Cần điều tra DLQ/replay sau khi AI hồi phục."
- **Metrics cần tạo/forward**: `queue_depth`, `api_latency_ms`, `cpu_usage_percent`, `memory_usage_percent`; dashboard phụ có thể đo DLQ/fallback counters.

---

## 1. Test coverage

| Test type | Tool | Coverage / Scope |
|---|---|---|
| Unit test | pytest / go test | `<X%>` - chưa có số liệu, cần bổ sung từ CI report |
| Integration test | Custom k6 script + Postman | Luồng ghi metric (`ledger-service` → collector/app remote_write → AMP) + Luồng dự báo và xử lý bất đồng bộ (Amazon SQS → `kyc-worker` → AI/Fallback Engine → Amazon DynamoDB) |
| E2E test | k6 (4 scenario script, xem §3.5) | SC-01 Gradual Drift, SC-02 Sudden Spike, SC-03 Slow Leak, SC-04 Noisy Baseline & AI Down |
| Load test | k6 (`stages` cho SC-01/03, `ramping-arrival-rate` cho SC-02) | Sustained 800-1,500 RPS (SC-01/03), burst 4,500 RPS (SC-02), peak target synthetic có thể scale down trong sandbox tùy ngân sách |
| Chaos test | Manual + k6 injected fault | 4 kịch bản: Gradual Drift, Sudden Spike, Slow Leak (memory), AI Down/Fallback |

---

## 2. SLO evidence

| SLO | Target | Measured | Window | Pass/Fail |
|---|---|---|---|---|
| API availability | ≥ 99.5% | `<X%>` | 2 weeks build period | `<✓/✗>` |
| P99 latency (ledger-service / payment-gateway) | < 350ms (SLA cứng theo SC-01/02) | `<Xms>` | Rolling 60s trong test window | `<✓/✗>` |
| Error rate (5xx, SC-02 spike) | < 5% | `<X%>` | Rolling 30s tại peak | `<✓/✗>` |
| Budget / cost guard | Platform baseline < $200/month before buffer | `<X USD>` | Full-month estimate + W12 test window actual | `<✓/✗>` |

### 2.1 SLO breach analysis

- Các ngưỡng cost (Circuit Breaker $40 cho SC-02, Sampling Throttle $30 cho SC-03) hiện là `[Hypothesis/TBD]`, cần calibrate lại sau Sandbox Run W12 trước khi dùng làm SLO chính thức.
- Nếu `ledger_p99_latency_ms` vượt 350ms liên tục ≥ 60s ở SC-01, root cause nghi vấn ưu tiên: AMP remote-write/query backpressure (ledger-service ghi metric vào AMP) hoặc ECS Task CPU chạm ngưỡng 85%.

### 2.2 TF4 KPI Mapping

> **Draft — chưa có số liệu thực.** Bảng này định nghĩa KPI cần đo sau khi chạy W12; giá trị Measured sẽ điền sau W12 Day 5.

| KPI | Định nghĩa | Target | Stretch target | Scenario liên quan | Measured | Pass/Fail |
|---|---|---|---|---|---|---|
| **Detection Latency** | Thời gian từ khi anomaly xuất hiện đến khi Warning được phát ra | ≤ 5 phút | — | SC-01, SC-04 | `<X phút>` | `<✓/✗>` |
| **SLO Breach Lead Time** | Khoảng thời gian hệ thống cảnh báo trước khi SLA thực sự bị vi phạm | ≥ 15 phút | — | SC-01 | `<X phút>` | `<✓/✗>` |
| **False Positive Rate (FP)** | % cảnh báo sai / tổng cảnh báo phát ra | ≤ 12% | ≤ 10% | SC-01, SC-02, SC-04 | `<X%>` | `<✓/✗>` |
| **Anomaly Catch Rate** | % kịch bản lỗi được phát hiện đúng / tổng kịch bản inject | ≥ 80% | ≥ 90% | SC-01 → SC-04 | `<X%>` | `<✓/✗>` |
| **Fallback Activation Rate** | % lần AI timeout dẫn tới Fallback Engine kích hoạt đúng | 100% khi AI timeout vượt Worker hard limit 2,000ms | — | SC-04 | `<X%>` | `<✓/✗>` |
| **Audit Decision Coverage** | % quyết định Fallback được ghi đầy đủ vào DynamoDB Audit log | 100% | — | SC-04 | `<X%>` | `<✓/✗>` |


## 3. Load test results

### 3.1 Test setup

- **Load profile** _(synthetic target — có thể scale down trong sandbox tùy ngân sách EC2)_: 4 kịch bản song song với peak thiết kế 50,000 events/sec:
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

> **Lưu ý:** Đây là **hypothesis thiết kế** dựa trên kinh nghiệm và pattern kiến trúc, chưa phải kết quả đo thực tế. Cần verify sau khi chạy W12.

- **SC-01 (hypothesis)**: Độ trễ ghi (RemoteWrite Latency) hoặc query của AMP có thể tăng dưới áp lực backpressure/cardinality khi `ledger-service` ghi lượng lớn — cần quan sát CloudWatch metric trong W12.
- **SC-02 (hypothesis)**: Public ALB ingest path hoặc ECS Service Connect proxy/task headroom có thể thành bottleneck khi `payment-gateway` gặp tải burst — cần đo thực tế thời gian scale-out và proxy CPU/memory.
- **SC-03 (hypothesis)**: `ledger-service` có thể có memory/thread leak không giải phóng sau GC — nguy cơ OOM ước tính ~4.2 tiếng, cần soak test thực tế xác nhận.
- **SC-04 (hypothesis)**: AI timeout vượt Worker hard limit 2,000ms có thể làm tắc nghẽn SQS và đẩy message xuống DLQ — cần verify Fallback Engine kích hoạt đúng ngưỡng.

### 3.4 Infrastructure prerequisites (Đồng bộ Architecture Baseline v1.0)

| ECS Service | Task CPU / RAM | Task Count | Ghi chú |
|---|---|---|---|
| `ledger-service` mock fixture | 1 vCPU / 2 GB RAM | 3 Tasks trong test window | ECS Auto-scaling **disabled** với SC-01, SC-03; không nằm trong monthly platform baseline |
| `payment-gateway` mock fixture | 4 vCPU / 8 GB RAM | 2 Tasks trong test window | Rate limiter **disabled** tại ALB để đo raw capacity trong SC-02; không nằm trong monthly platform baseline |
| `kyc-worker` mock fixture | 2 vCPU / 4 GB RAM | 5 Tasks trong test window | SQS visibility timeout = 30s; AI endpoint mock-timeout cho SC-04; không nằm trong monthly platform baseline |
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
    'https://<public-alb-dns>/v1/ingest',
    JSON.stringify({ tenant_id: 'tenant-001', service_id: 'ledger-service', metric_type: 'api_latency_ms', ts: new Date().toISOString(), value: Math.random() * 100 }),
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
  const payload = JSON.stringify({ tenant_id: 'tenant-001', service_id: 'payment-gateway', metric_type: 'api_latency_ms', ts: new Date().toISOString(), value: Math.random() * 1000 });
  const params  = { headers: { 'Content-Type': 'application/json' }, tags: { scenario: 'SC-02' } };
  const res = http.post('https://<public-alb-dns>/v1/ingest', payload, params);
  check(res, { 'status not 5xx': (r) => r.status < 500 });
}
```

### 3.6 Quy trình Reset & Khôi phục môi trường (Post-Test Cleanup)

Để loại bỏ triệt để hiện tượng nhiễm độc dữ liệu kiểm thử (Test Contamination), quy trình dọn dẹp bắt buộc phải chạy tự động sau mỗi scenario. **Lưu ý:** Hệ thống chạy trên AWS ECS Fargate — không dùng kubectl; cleanup thực hiện qua AWS CLI / ECS API.

- **Clear Memory Leak (SC-03):** Force new deployment để ECS Fargate thay thế toàn bộ Task bằng instance sạch, đưa bộ nhớ về trạng thái ban đầu:
  ```bash
  aws ecs update-service \
    --cluster foresight-staging \
    --service ledger-service \
    --force-new-deployment \
    --region us-east-1
  ```
- **Purge Hàng đợi (SC-04):** Xóa sạch tin nhắn tồn đọng trên SQS và DLQ trước khi chạy kịch bản tiếp theo:
  ```bash
  aws sqs purge-queue --queue-url $KYC_SQS_URL  --region us-east-1
  aws sqs purge-queue --queue-url $KYC_DLQ_URL  --region us-east-1
  ```

---

## 4. Security test

### 4.1 Penetration touch points

- ☐ Public `/v1/ingest` auth/schema bypass attempt
- ☐ Cross-tenant data leak attempt across AMP labels, DynamoDB audit and S3 evidence
- ☐ SQL injection / NoSQL injection
- ☐ IAM privilege escalation giữa ECS Task roles, including AMP write role vs query role
- ☐ Secret/SigV4 exposure via logs, including Authorization header, credential scope and webhook/tenant token

### 4.2 Vulnerability scan

- **Tool**: Trivy / Snyk / AWS Inspector `<chưa xác nhận tool chính thức>`
- **CRITICAL findings**: `<0 - cần xác nhận>`
- **HIGH findings**: `<≤ 3 với mitigation - cần xác nhận>`
- **Report**: `<repo>/security/scan-results.json`

---

## 5. Multi-tenant isolation test

| Test Method | Request Detail | Result |
|---|---|---|
| Tenant A reads Tenant B data via API | Inject token tenant A, request tenant B evidence/query | ❌ Should fail with 403 - `<chưa chạy>` |
| Cross-tenant queue contamination | Tenant A enqueue SQS với `tenant_id` của B (liên quan flow SC-04) | Audit log (DynamoDB) catches mismatch - `<chưa chạy>` |
| AMP label isolation | Query AMP series của tenant khác qua API trên `ledger-service` | Should return empty / error - `<chưa chạy>` |
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
- **Gap 2**: Ngưỡng cost/circuit breaker trong scenario là giả định `[Hypothesis/TBD]`, cần calibrate lại theo AWS Pricing thực tế sau Sandbox Run. Full-month platform baseline dùng `05_cost_analysis.md`, còn mock service/k6 cost là test-window-only.
- **Gap 3**: Penetration test và vulnerability scan (mục 4) chưa có lịch chạy cụ thể, cần xác nhận tool và schedule với Security team.
- **Gap 4**: Multi-tenant isolation test (mục 5) chưa chạy - đây là rủi ro cao nhất vì leak = SEV1, cần ưu tiên trước capstone.

---

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - SLO targets và Architecture Baseline v1.0 validated trong §3 doc này
- [`03_security_design.md`](03_security_design.md) §14 - Risk registry mitigated bởi test results §6 doc này
- [`../../ai/docs/04_eval_report.md`](../../ai/docs/04_eval_report.md) - Joint eval: AI engine quality (Fallback Engine SC-04) + CDO infra integration
