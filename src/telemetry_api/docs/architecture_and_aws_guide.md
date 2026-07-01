# CDO Telemetry API — Hướng dẫn Mapping Code Hạ tầng AWS & Kiểm thử

Tài liệu này hướng dẫn chi tiết cách ánh xạ (mapping) cấu trúc code Python/FastAPI hiện tại sang các dịch vụ hạ tầng AWS tương ứng và cách thực hiện kiểm thử vận hành ở cả hai chế độ `APP_MODE=local` và `APP_MODE=aws`.

---

## 1. Bản đồ Ánh xạ: Code Components ↔ AWS Infrastructure

Chế độ chạy của hệ thống được chuyển đổi linh hoạt qua biến môi trường `APP_MODE`:

| Thành phần trong Code (`src/`) | Tài nguyên AWS tương ứng (Production) | Mô tả hành vi & Vai trò |
| :--- | :--- | :--- |
| **`APP_MODE=aws`** | **ECS Fargate / ALB** | Kích hoạt cấu hình production, sử dụng các SDK AWS thực tế và tắt các file mock cục bộ. |
| **`AmpTelemetryAdapter` (`storage_adapter`)** | **Amazon Managed Service for Prometheus (AMP)** | Thực hiện lưu trữ No-Op tại Ingest API. Đột phá qua việc lưu in-memory Prometheus Gauges và expose tại `/metrics` để ADOT Collector scrape. |
| **`AmpDeliveryAdapter`** | **Không dùng trong production AWS** | `AMP_DELIVERY_ENABLED=false` khi `APP_MODE=aws`. Adapter chỉ dùng cho local dev/test/replay. Production dùng ADOT Collector sidecar scrape `/metrics` và SigV4 remote_write vào AMP. |
| **`prometheus_exporter`** | **ADOT Collector (Sidecar)** | Expose endpoint `/metrics` định dạng Prometheus. ADOT Collector scrape định kỳ (15s) và remote_write về AMP sử dụng chữ ký IAM SigV4. |
| **`s3_failure_buffer_adapter`** | **Amazon S3 Bucket** | Chỉ buffer lỗi app-direct/local replay path. Production AWS dùng ADOT sidecar async nên lỗi ADOT remote_write không tự rơi vào S3; kiểm tra bằng ADOT logs + AMP query. |
| **`replay_service`** | **ECS Scheduled Task / EventBridge** | Quét bucket S3 định kỳ, đọc các bản ghi lỗi, gửi lại (replay) tới AMP và dọn dẹp (delete) object khi hoàn tất. |
| **`idempotency.py`** | **AMP Deduplication & S3 Key Partitioning** | Sinh khóa duy nhất dựa trên SHA-256 bhash các trường dữ liệu được sắp xếp nhằm chống trùng lặp dữ liệu trên AMP và làm khóa phân vùng S3. |
| **`core/logging.py`** | **Amazon CloudWatch Logs** | Ghi log dưới định dạng JSON cấu trúc (Structured JSON Logs) chuyển tiếp trực tiếp vào CloudWatch Log Group `/ecs/tf4-cdo04-telemetry-api`. |

---

## 2. Quy tắc Phân vùng Dữ liệu S3 (S3 Partitioning Schema)

Khi app-direct/local delivery path ghi failure buffer, dữ liệu được ghi xuống S3 theo cấu trúc phân vùng tối ưu hóa cho truy vấn Athena/Glue. Với production ADOT sidecar, ADOT remote_write lỗi được xử lý bằng retry/queue nội bộ và không tạo object S3:

```text
s3://<S3_FAILURE_BUFFER_BUCKET>/telemetry-failures/tenant_id=<tenant_id>/service_id=<service_id>/metric_type=<metric_type>/date=<YYYY-MM-DD>/idempotency_key=<hash>.json
```

* **`date`**: Định dạng `YYYY-MM-DD` được trích xuất động từ trường thời gian `ts` của telemetry payload.
* **`idempotency_key`**: Khóa SHA-256 mã hóa của:
  `sha256(tenant_id + service_id + metric_type + ts + value + sorted_labels)`

---

## 3. Hướng dẫn Kiểm thử & Xác minh Vận hành (Testing & Operation Guide)

### 3.1 Kiểm thử Unit & Integration cục bộ (Local Testing)
Để đảm bảo toàn bộ 113 kịch bản kiểm thử (Idempotency, Schema Validation, Denial lists, Retries, Failure Buffer, Replay) hoạt động tốt:

```bash
# Chạy bộ kiểm thử tự động bằng pytest từ thư mục src/
cd src/
python -m pytest
```

### 3.2 Diễn tập Kiểm thử trên Môi trường AWS (AWS Verification & Game Day)

#### Bước 1: Khởi tạo Telemetry API ở chế độ AWS
Thiết lập các biến môi trường trong ECS Task Definition:
```env
APP_MODE=aws
ENV=prod
AWS_REGION=us-east-1
AMP_DELIVERY_ENABLED=false
S3_FAILURE_BUFFER_BUCKET=cdo-telemetry-failure-buffer
AMP_REMOTE_WRITE_ENDPOINT=https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-xxx/api/v1/remote_write
```

#### Bước 2: Kiểm tra trạng thái sức khỏe
```bash
curl -i https://<API_GATEWAY_BASE_URL>/health
```
**Kết quả mong đợi (HTTP 200 OK):**
```json
{
  "status": "ok",
  "service": "telemetry-api",
  "version": "0.1.0",
  "environment": "prod",
  "app_mode": "aws",
  "storage_backend": "prometheus_amp"
}
```

#### Bước 3: Gửi Telemetry Hợp lệ
```bash
curl -X POST https://<API_GATEWAY_BASE_URL>/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: test-aws-ingest-001" \
  -d '{
    "ts": "2026-06-29T11:00:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 250.0,
    "labels": {
      "region": "us-east-1"
    }
  }'
```
* **Phản hồi**: `201 Created`
* **Xác minh**: Truy xuất endpoint `/metrics` để xem Prometheus Gauge được cập nhật.

#### Bước 4: Giả lập Sự cố AMP (Trích xuất lỗi sang S3 Buffer)
1. Cấu hình biến môi trường tạm thời: `FORCE_AMP_DELIVERY_FAIL=true`
2. Thực hiện lại request `POST /v1/ingest`.
3. **Phản hồi**: `202 Accepted` (Trạng thái dữ liệu được ghi nhận vào S3 thành công).
4. **Kiểm tra S3**:
   ```bash
   aws s3 ls s3://cdo-telemetry-failure-buffer/telemetry-failures/ --recursive
   ```

#### Bước 5: Kiểm tra Replay thủ công
Khi sự cố AMP được khắc phục (Gỡ bỏ `FORCE_AMP_DELIVERY_FAIL`), chạy replay để đẩy lại dữ liệu:
```bash
python -m telemetry_api.services.replay_service
```
* **Log output**:
  `INFO: Replay success for s3://cdo-telemetry-failure-buffer/telemetry-failures/... Deleting object.`
