# CDO-W12-019 — ADOT/Prometheus Agent remote_write path

## 1. Tổng quan & Mục tiêu
Tối ưu hóa luồng truyền tải metrics tới Amazon Managed Service for Prometheus (AMP). Thay vì tự viết client gửi raw protobuf qua giao thức Snappy + SigV4 (phức tạp và tốn tài nguyên), hệ thống sử dụng AWS Distro for OpenTelemetry (ADOT) Collector hoặc Prometheus Agent làm sidecar để scrape endpoint `/metrics` định dạng Prometheus của API và thực hiện `remote_write` không đồng bộ, an toàn vào AMP bằng chữ ký AWS SigV4.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **API phát ra Prometheus Samples**: Telemetry API cung cấp endpoint `/metrics` theo chuẩn exposition format của Prometheus.
- [x] **AMP nhận metric thành công**: Dữ liệu được gửi thành công đến AMP thông qua ADOT pipeline.
- [x] **Truy vấn PromQL**: Có khả năng dùng PromQL trên AMP để truy vấn các chỉ số mới (ví dụ: `cpu_usage_percent`, `api_latency_ms`).
- [x] **IAM Role với quyền `aps:RemoteWrite`**: IAM role gắn cho ECS Task chứa policy cho phép thực hiện remote_write vào AMP.
- [x] **Không sử dụng Long-lived Tokens**: Không lưu trữ static token hay credentials dài hạn, xác thực SigV4 được ký động thông qua service account/IAM role.
- [x] **Bằng chứng xác thực (Evidence)**: Sẵn sàng các chỉ dẫn cấu hình và Log xác nhận thành công.

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/adot-config.yaml](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/adot-config.yaml): File cấu hình tham chiếu của ADOT Collector, định nghĩa receiver `prometheus` scrape API ở cổng 8080 và exporter `prometheusremotewrite` tích hợp extension `sigv4auth`.
- [src/telemetry_api/routes/metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/routes/metrics.py): Hiện thực endpoint GET `/metrics` trả về dữ liệu định dạng text tương thích với Prometheus.
- [src/telemetry_api/observability/prometheus_exporter.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/observability/prometheus_exporter.py): Khởi tạo registry, định nghĩa nhãn Prometheus cho 7 AI signals và cập nhật giá trị Gauges thời gian thực khi nhận request.
- [src/telemetry_api/tests/telemetry_api/test_prometheus_metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_prometheus_metrics.py): Bộ kiểm thử xác thực cấu trúc đầu ra của `/metrics` chứa đầy đủ tên metric và danh sách nhãn.

## 4. Chi tiết hiện thực hóa và Hạ tầng AWS

### Kiến trúc luồng Metric:
```text
[Telemetry API (Port 8080)]
         │
         ▼ (Scraped via /metrics every 15s)
[ADOT Collector (Sidecar)]
         │
         ▼ (Sign with AWS SigV4 Auth using Task IAM Role)
[Amazon Managed Service for Prometheus (AMP)]
```

### Cấu hình ADOT Collector (`adot-config.yaml`):
1. **Receiver**: Cấu hình `prometheus` scrape target `localhost:8080` (hoặc cổng chạy ứng dụng) định kỳ mỗi 15 giây.
2. **Extensions**: Kích hoạt `sigv4auth` với region và service name `aps` (Amazon Prometheus Service).
3. **Exporter**: Dùng `prometheusremotewrite` trỏ endpoint đến AWS AMP workspace endpoint và gắn bộ xác thực `sigv4auth`.

### IAM Policy yêu cầu cho ECS Task Role:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ],
      "Resource": "*"
    }
  ]
}
```
*(Lưu ý: Không cần cấu hình long-lived credentials, ADOT tự động lấy temporary credentials được cung cấp bởi AWS ECS Agent).*
