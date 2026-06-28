# Source

Place platform integration code here.

Expected integration points:

- emit telemetry according to `contracts/telemetry-contract.md`
- call AI endpoint according to `contracts/ai-api-contract.md`
- implement fallback behavior for timeout/503
- write audit evidence according to `docs/03_security_design.md`

---

## Telemetry API - CDO-W12-015 & CDO-W12-016

This repo now includes a local-first Telemetry API implementation for:

```text
POST /v1/ingest
GET /health
GET /metrics
```

The task implements the telemetry ingress boundary. Valid ingest requests are persisted to local JSONL storage at `local-store/telemetry.jsonl`.

### Configuration

Supported environment variables:

```env
APP_NAME=telemetry-api
APP_VERSION=0.1.0
BUILD_ID=local
GIT_COMMIT_SHA=unknown
ENV=local
PORT=8000
MAX_INGEST_PAYLOAD_BYTES=65536
TELEMETRY_STORAGE_BACKEND=local_jsonl
LOCAL_TELEMETRY_FILE=local-store/telemetry.jsonl
LOG_LEVEL=INFO
```

---

## CDO-W12-017 — PII and label denylist

### 1. Tại sao không được lưu PII trong Telemetry Metrics?
Việc lưu trữ thông tin xác định danh tính cá nhân (PII - Personally Identifiable Information) như email, số điện thoại, số tài khoản ngân hàng trong hệ thống giám sát (telemetry/logs) vi phạm nghiêm trọng các quy định bảo mật dữ liệu toàn cầu (như GDPR, PCI-DSS) và quy chuẩn của dự án Foresight Lens. Dữ liệu telemetry phải tuyệt đối ẩn danh.

### 2. Tại sao nhãn có Cardinality cao (High-Cardinality) lại nguy hiểm?
Trong các cơ sở dữ liệu thời gian thực (Time Series Database như Prometheus, AMP), mỗi tổ hợp các nhãn (labels) độc nhất tạo ra một Time Series mới. Nếu chúng ta dùng các nhãn có độ phân tán cao (ví dụ: `request_id`, `session_id`, `transaction_id` hay raw path chứa ID động), số lượng chuỗi thời gian sẽ tăng lên theo cấp số nhân (cardinality explosion). Điều này làm cạn kiệt bộ nhớ hệ thống, suy giảm hiệu năng truy vấn nghiêm trọng và làm tăng chi phí lưu trữ trên AWS.

### 3. Chính sách xử lý (Reject Policy)
Hệ thống áp dụng chính sách **REJECT_POLICY** (Từ chối tuyệt đối):
- Mọi request vi phạm denylist hoặc chứa nhãn nguy hiểm sẽ lập tức bị chặn tại ranh giới Ingest và trả về mã lỗi `HTTP 400 Bad Request`.
- **Không** âm thầm loại bỏ (silent strip).
- **Không** ghi dữ liệu lỗi vào file lưu trữ local JSONL hoặc gọi adapter AMP sau này.
- **Không** in các giá trị nhạy cảm ra file log (chỉ log tên key bị cấm và lý do từ chối để phục vụ audit/debug).

### 4. Danh sách các quy tắc lọc nhãn (Denylist Rules)

#### A. Key nhãn bị cấm (PII Denylist):
- `email`, `phone`, `name`, `transaction_id`, `account_id`, `card_pan`, `user_id`, `request_id`, `trace_id`, `prediction_id`.

#### B. Key nhãn có Cardinality cao bị cấm:
- `request_id`, `trace_id`, `session_id`, `user_id`, `transaction_id`, `prediction_id`, `account_id`, `card_pan`, `raw_path`, `path_with_id`.

#### C. Value nhạy cảm bị cấm (Sensitive Value Markers):
- Nếu giá trị của nhãn chứa các chuỗi con sau (không phân biệt hoa thường) sẽ bị cấm:
  - `email`, `phone`, `password`, `token`, `secret`, `authorization`, `api_key`, `credential`, `card_pan`, `account_id`, `transaction_id`.

#### D. Đường dẫn Endpoint thô chứa ID động (Raw Endpoint Path with IDs):
- Mọi giá trị nhãn trông giống như đường dẫn endpoint thô chứa ID động (ví dụ: `/users/12345/orders/98765`, `/api/v1/users/550e8400-e29b-41d4-a716-446655440000`) đều bị từ chối.
- Đường dẫn tham số hóa an toàn (ví dụ: `/accounts/{account_id}/transactions/{transaction_id}`) **được phép** hoạt động bình thường.

#### Ví dụ nhãn An toàn (Safe Labels):
- `region`, `env`, `service_tier`, `db_type`, `queue_name`, `cache_type`, `source`, `aws_namespace`.

### 5. Hành vi đo lường (Metrics Endpoint)
Khi có một request bị từ chối do vi phạm PII hoặc Cardinality, bộ đếm metrics cục bộ tại endpoint `/metrics` sẽ tăng lên tương ứng:
- `telemetry_ingest_pii_rejected_total` (+1 khi vi phạm PII/Denylist).
- `telemetry_ingest_cardinality_rejected_total` (+1 khi vi phạm Cardinality hoặc Raw path).
- `telemetry_ingest_rejected_by_reason` tăng tương ứng với các lý do cụ thể: `pii_denylist_label`, `high_cardinality_label`, `raw_endpoint_path_with_ids`.

> [!NOTE]
> *Lưu ý về CloudWatch:* Các bộ đếm cục bộ này được thiết kế tương thích sẵn sàng để xuất (CloudWatch-ready). Khi deploy trên môi trường AWS thật, các sự kiện này sẽ được đẩy trực tiếp thành các custom metrics của AWS CloudWatch.

---

## CDO-W12-018 — Metric allowlist

### 1. Tổng quan chính sách lọc Metric (AI_SIGNAL_ALLOWLIST_ONLY)
Mục tiêu là đảm bảo chỉ đúng 7 AI signals đã được ký kết trong telemetry contract mới được phép ingest vào hệ thống.
Hệ thống áp dụng chính sách nghiêm ngặt:
- Mọi metric nằm ngoài allowlist (chứa 7 signals) đều bị từ chối với mã lỗi `HTTP 400 Bad Request`.
- Các metric nội bộ (`error_rate` và `oldest_message_age_seconds`) mặc dù được định nghĩa nhưng chưa nằm trong contract nên bị chặn hoàn toàn khỏi AI pipeline.
- Dữ liệu bị reject tuyệt đối không được ghi vào file local JSONL (`telemetry.jsonl`) hay gọi adapter AMP trong tương lai.

### 2. Danh sách 7 AI Signals và Nhãn bắt buộc (Required Labels)

Mỗi metric trong allowlist yêu cầu một tập nhãn bắt buộc riêng biệt để đảm bảo tính phân tích chính xác:

| metric_type | Nhãn bắt buộc (Required labels) |
| :--- | :--- |
| `cpu_usage_percent` | `region` |
| `memory_usage_percent` | `region` |
| `active_connections` | `region` |
| `api_latency_ms` | `region` |
| `db_connection_pool_pct` | `region`, `db_type` |
| `queue_depth` | `region`, `queue_name` |
| `cache_hit_rate_pct` | `region`, `cache_type` |

> [!IMPORTANT]
> - Nếu thiếu nhãn bắt buộc -> Trả về lỗi 400 (`missing_required_label`).
> - Nếu nhãn bắt buộc truyền lên nhưng giá trị rỗng/khoảng trắng -> Trả về lỗi 400 (`empty_required_label`).
> - Nhãn bắt buộc vẫn phải vượt qua toàn bộ kiểm tra PII/Cardinality (ví dụ: `queue_name` không được chứa thông tin nhạy cảm).
> - *Lưu ý tương lai:* Nếu AI contract ký kết thêm metric mới, chỉ cần cập nhật allowlist trong `validators/metrics.py` và bổ sung unit tests.

### 3. Hành vi đo lường (Metrics Endpoint)
Các bộ đếm cục bộ phục vụ giám sát việc chặn lọc metric tại `/metrics` bao gồm:
- `telemetry_ingest_unsupported_metric_rejected_total` (+1 khi gửi metric ngoài allowlist).
- `telemetry_ingest_internal_only_metric_rejected_total` (+1 khi gửi metric chỉ dùng nội bộ).
- `telemetry_ingest_metric_label_rejected_total` (+1 khi thiếu hoặc rỗng nhãn bắt buộc).
- `telemetry_ingest_rejected_by_reason` tăng tương ứng với các lý do: `unsupported_metric_type`, `internal_only_metric_not_ai_signal`, `missing_required_label`, `empty_required_label`.

---

## CDO-W12-021 — /health endpoint

### 1. Mục đích của endpoint `/health`
Endpoint `/health` được thiết kế để cung cấp thông tin kiểm tra sức khỏe của container / ứng dụng. Endpoint này được sử dụng bởi:
- Nhà phát triển khi muốn kiểm tra API còn hoạt động bình thường (Local verification).
- Docker daemon thực hiện container health check thông qua Dockerfile `HEALTHCHECK`.
- AWS Application Load Balancer (ALB) và AWS ECS Service để quyết định điều phối lưu lượng (Target Group health check).

### 2. Thiết kế bảo mật (No Secret Leakage)
Endpoint trả về một payload JSON chứa các thông tin tối giản và không có quyền truy cập. Hệ thống đảm bảo **tuyệt đối không trả về** hoặc rò rỉ bất kỳ bí mật hay cấu hình riêng tư nào của hệ thống (như database connection string, AWS Credentials, API Key, private variables, tokens).

### 3. Lệnh gọi mẫu thử nghiệm thủ công (Sample Curl)

Gửi request kiểm tra sức khỏe:
```bash
curl -i http://localhost:8000/health
```

**Phản hồi kỳ vọng:**
```text
HTTP/1.1 200 OK
Content-Type: application/json
```
```json
{
  "status": "ok",
  "service": "telemetry-api",
  "version": "0.1.0",
  "build_id": "local",
  "commit_sha": "unknown",
  "environment": "local"
}
```

### 4. Cấu hình Docker Healthcheck
Nếu đóng gói ứng dụng qua Dockerfile, cấu hình health check như sau:

* **Sử dụng lệnh curl (Nếu container image có sẵn curl):**
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1
  ```

* **Sử dụng Python Fallback (Nếu container image tối giản không có curl):**
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=3)" || exit 1
  ```

### 5. Đặc tả cấu hình AWS ECS / ALB Health Check
Khi triển khai trên AWS ECS/ALB Target Group, cấu hình tham số kiểm tra sức khỏe như sau:
- **Health Check Path**: `/health`
- **Expected Status Code**: `200`
- **Interval**: `30` giây
- **Timeout**: `5` giây
- **Healthy Threshold**: `2`
- **Unhealthy Threshold**: `3`

---

## Lệnh gọi mẫu thử nghiệm thủ công cho /v1/ingest (Sample Curls)

### A. Request hợp lệ (Valid Ingest):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: metric-valid-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1"
    }
  }'
```

### B. Request lỗi do Metric không được hỗ trợ (Unsupported Metric):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: metric-invalid-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "random_metric",
    "value": 123,
    "labels": {
      "region": "us-east-1"
    }
  }'
```
*Phản hồi trả về:* `HTTP 400 Bad Request` với message: `metric_type is not in AI signal allowlist: random_metric`.

### C. Request lỗi do Metric nội bộ (Internal-only Metric):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: metric-internal-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "error_rate",
    "value": 0.03,
    "labels": {
      "region": "us-east-1"
    }
  }'
```
*Phản hồi trả về:* `HTTP 400 Bad Request` với message: `metric_type is internal-only and must not be sent as AI signal: error_rate`.

### D. Request lỗi do thiếu nhãn bắt buộc (Missing Required Label):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: metric-missing-label-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "kyc-worker",
    "metric_type": "queue_depth",
    "value": 240,
    "labels": {
      "region": "us-east-1"
    }
  }'
```
*Phản hồi trả về:* `HTTP 400 Bad Request` với message: `metric_type queue_depth requires label: queue_name`.

---

## Hướng dẫn chạy và kiểm thử cục bộ

### 1. Khởi chạy API locally:
```bash
$env:PYTHONPATH="src"
python -m uvicorn telemetry_api.main:app --host 0.0.0.0 --port 8000
```

### 2. Chạy toàn bộ 94 unit tests tự động:
```bash
$env:PYTHONPATH="src"
pytest -sv src/telemetry_api
```
