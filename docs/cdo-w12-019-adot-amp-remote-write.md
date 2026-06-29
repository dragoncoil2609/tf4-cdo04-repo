# CDO-W12-019 — ADOT/Prometheus Agent remote_write path

Tài liệu này hướng dẫn chi tiết cách cấu hình, luồng dữ liệu, phân tích thiết kế và cách xác thực tính năng tích hợp Amazon Managed Service for Prometheus (AMP) thông qua ADOT Collector hoặc Prometheus Agent cho Telemetry Ingest API.

## 1. Mục tiêu & Quyết định thiết kế

### 1.1 Mục tiêu
Thiết lập đường dẫn dữ liệu ổn định từ API Client gửi về `POST /v1/ingest`, đi qua tất cả các quy tắc lọc và xác thực (schema validation, tenant header matching, PII/cardinality filters, metric allowlist), lưu trữ cục bộ, sau đó expose qua định dạng Prometheus exposition text ở `/metrics` để ADOT Collector scrape và remote_write về AMP dùng IAM SigV4.

### 1.2 Quyết định không tự viết raw remote_write
Việc tự implement API Client tự mã hóa dữ liệu theo cấu trúc Protobuf và nén bằng Snappy, đồng thời tự thực hiện ký SigV4 cho mỗi request remote_write đòi hỏi độ phức tạp rất cao về xử lý mạng, hàng đợi (queue), cơ chế retry, backoff và tiêu tốn nhiều tài nguyên CPU của Telemetry Ingest API. 
Do đó, chúng tôi quyết định sử dụng giải pháp chuẩn hóa của AWS: **ADOT Collector** (hoặc Prometheus Agent) chạy sidecar/service để thực hiện scrape bất đồng bộ từ `/metrics` và chịu trách nhiệm đóng gói, nén, ký SigV4 và đẩy dữ liệu lên AMP.

## 2. Luồng dữ liệu (Architecture Flow)
```text
[API Client]
     │ (HTTP POST /v1/ingest)
     ▼
[Telemetry Ingest API]
     │ 1. Schema Validation (ts, value)
     │ 2. Tenant Header matching (X-Tenant-Id)
     │ 3. PII & High-Cardinality Denylist filter
     │ 4. Metric Allowlist validation
     ├─► [Local Storage Adapter] (Ghi log/file local-store/telemetry.jsonl)
     ├─► [Prometheus Exporter] (Cập nhật Prometheus Gauges trong bộ nhớ app)
     ▼
[GET /metrics] <────────────────── Scrape (Mỗi 15s) ────────────────── [ADOT Collector]
 (Prometheus format)                                                          │
                                                                              │ remote_write
                                                                              │ (IAM SigV4 auth)
                                                                              ▼
                                                                        [Amazon AMP]
```

## 3. Các Metric & Nhãn An Toàn (Safe Labels)

### 3.1 7 AI Signals được hợp đồng cho phép
Chỉ 7 metrics này được phép ghi nhận và cập nhật vào Prometheus Exporter:
1. `cpu_usage_percent` (Gauge)
2. `memory_usage_percent` (Gauge)
3. `active_connections` (Gauge)
4. `db_connection_pool_pct` (Gauge)
5. `queue_depth` (Gauge)
6. `cache_hit_rate_pct` (Gauge)
7. `api_latency_ms` (Gauge)

Các metric không nằm trong allowlist (như `error_rate`, `oldest_message_age_seconds`, `business_revenue`) đều bị reject ở mức validation và không được cập nhật vào Prometheus Exporter.

### 3.2 Nhãn an toàn (Safe Labels Allowlist)
Chỉ cho phép các nhãn sau được đính kèm vào Prometheus timeseries:
- **Common labels:** `tenant_id`, `service_id`, `region`
- **Metric-specific labels:** `db_type`, `queue_name`, `cache_type`
- **Optional safe labels:** `env`, `service_tier`

Mọi nhãn nhạy cảm thuộc PII (email, phone, name, transaction_id, user_id, trace_id, request_id...) hoặc nhãn có cardinality cao đều bị chặn từ vòng validation ngoài và hoàn toàn không thể lọt vào Prometheus Exporter.

## 4. Cấu hình hạ tầng & IAM

### 4.1 ADOT Collector Config (`infra/adot/collector-config.yaml`)
Collector được cấu hình scrape endpoint `/metrics` của Telemetry API và remote_write sang AMP sử dụng extension `sigv4auth`.

### 4.2 IAM Policy (`infra/iam/amp-remote-write-policy.json`)
IAM Task Role chạy ADOT Collector chỉ cần quyền ghi tối thiểu lên workspace của AMP:
- Hành động: `aps:RemoteWrite`
- Resource: Scope cụ thể theo Workspace ARN của dự án.

## 5. Xác thực và Kiểm thử Local

### Bước 1: Khởi chạy ứng dụng Telemetry Ingest API
```bash
uvicorn src.telemetry_api.main:app --host 0.0.0.0 --port 8000
```

### Bước 2: Gửi request ingest payload hợp lệ
```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: cdo-w12-019-demo-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1",
      "env": "production"
    }
  }'
```

### Bước 3: Kiểm tra Prometheus exposition format ở `/metrics`
```bash
curl http://localhost:8000/metrics
```
**Kết quả kỳ vọng:**
```text
# HELP api_latency_ms Telemetry metric api_latency_ms
# TYPE api_latency_ms gauge
api_latency_ms{env="production",region="us-east-1",service_id="payment-gateway",service_tier="",tenant_id="demo-tenant-001"} 450.5
```

## 6. Xử lý sự cố (Troubleshooting)
1. **Endpoint `/metrics` không xuất hiện metric mới:**
   - Kiểm tra xem payload gửi lên đã vượt qua toàn bộ validation chưa (nếu bị reject, log sẽ có event `telemetry_ingest_rejected`).
   - Kiểm tra xem metric_type có nằm trong danh sách 7 AI signals cho phép hay không.
2. **ADOT Collector scrape thất bại:**
   - Đảm bảo Telemetry API bind vào `0.0.0.0` để container sidecar có thể gọi chéo.
   - Kiểm tra cấu hình `targets` trong `collector-config.yaml` khớp với endpoint thực tế.
3. **AMP trả lỗi 403 Forbidden hoặc AccessDenied:**
   - Xác thực ECS Task Role đã được gán IAM Policy chứa quyền `aps:RemoteWrite`.
   - Kiểm tra AWS Region và Workspace ID trong URL Remote Write.
