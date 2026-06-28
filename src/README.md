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

### 6. Lệnh gọi mẫu thử nghiệm thủ công (Sample Curl)

#### Request mẫu hợp lệ:
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: local-test-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1",
      "env": "local",
      "service_tier": "tier-1"
    }
  }'
```

#### Request lỗi do chứa nhãn PII (`email`):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: pii-test-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "email": "user@example.com"
    }
  }'
```
*Phản hồi trả về:* `HTTP 400 Bad Request`, bộ đếm `telemetry_ingest_pii_rejected_total` tăng 1. Log ghi nhận `reason: pii_denylist_label`, `denied_key: email` và không rò rỉ email thô ra log file.

#### Request lỗi do chứa nhãn Cardinality cao (`request_id`):
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: cardinality-test-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "request_id": "req-abc-123"
    }
  }'
```
*Phản hồi trả về:* `HTTP 400 Bad Request`, bộ đếm `telemetry_ingest_cardinality_rejected_total` tăng 1. Log ghi nhận `reason: high_cardinality_label`, `denied_key: request_id` và không chứa chuỗi ID động thô.

---

### 7. Cách chạy và kiểm thử

#### Khởi chạy API locally:
```bash
$env:PYTHONPATH="src"
python -m uvicorn telemetry_api.main:app --host 0.0.0.0 --port 8000
```

#### Chạy toàn bộ 73 unit tests tự động:
```bash
$env:PYTHONPATH="src"
pytest -sv src/telemetry_api
```
