# Báo cáo Kiểm thử & Đánh giá (Test & Eval Report) - Task force 4 · CDO Foresight Lens
 
<!-- Doc owner: Nhóm CDO / QA Lead
     Status: FINAL LIVE EVIDENCE CAPTURED - accepted for demo with noted k6 caveat
     Region: us-east-1
     Environment: sandbox
     Date updated: 2026-07-02 -->
 
## 1. Nhận định chung (Executive verdict)
 
**Verdict: ĐẠT (PASS) cho capstone demo / hội đồng mentor review, kèm theo k6 caveat đã được ghi nhận.**
 
Bằng chứng thực tế (Live evidence) chứng minh:
 
```text
Luồng Telemetry ingest qua API Gateway AWS_IAM hoạt động ổn định.
3 dịch vụ canonical gửi metrics thành công cho tenant demo-tenant-001.
Prediction worker truy vấn thành công dữ liệu từ AMP và kết nối được tới AI Engine.
Bảng DynamoDB audit lưu trữ đầy đủ các bản ghi thành công với AI_ENGINE + complete_window + ai_status_code=200.
Đợt chạy ingest 3h ở mức tải 50 RPS duy trì thành công tải mục tiêu với các chỉ số SLO về độ trễ (latency) và tỷ lệ lỗi (error) xuất sắc.
```
 
Caveat được ghi nhận rõ ràng:
 
```text
Kịch bản k6 chạy 3h trả về mã thoát (exit code) 99 do vi phạm điều kiện ràng buộc nghiêm ngặt dropped_iterations < 1.
Ghi nhận 27 dropped iterations và 19 requests thất bại trên tổng số 539,974 requests.
Tỷ lệ lỗi (Failure rate) đạt 0.0035%, nằm dưới ngưỡng giới hạn <1%.
Không mô tả kết quả này như một đợt chạy pass k6 zero-drop hoàn hảo.
```
 
## 2. Các tập tin bằng chứng (Evidence files)
 
Bằng chứng vận hành thực tế nằm trong thư mục `evidence/logs/`.
 
| Bằng chứng (Evidence) | Tập tin (File) |
|---|---|
| Mục lục bằng chứng thực tế được lọc | [`evidence/logs/live-testing-20260701-141831/curated/README.md`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/README.md) |
| Tóm tắt đợt chạy khói (smoke test) 2m 50 RPS | [`evidence/logs/live-testing-20260701-141831/curated/k6-50rps-2m-summary.json`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/k6-50rps-2m-summary.json) |
| Tóm tắt đợt chạy cuối 3h 50 RPS | [`evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-summary.json`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-summary.json) |
| Log tóm tắt cuối đợt chạy k6 3h | [`evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-log-thresholds.txt`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-log-thresholds.txt) |
| Bằng chứng xác thực khói SigV4 | [`evidence/logs/live-testing-20260701-141831/curated/preflight-post-apply-smoke-signed.log`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/preflight-post-apply-smoke-signed.log) |
| Tóm tắt kết quả poll cuối cùng | [`evidence/logs/live-testing-20260701-141831/curated/poll-final-summary.tsv`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/poll-final-summary.tsv) |
| Mẫu bản ghi DynamoDB audit | [`evidence/logs/live-testing-20260701-141831/curated/poll-*-audit-sample.json`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/) |
| Mẫu kết quả truy vấn AMP | [`evidence/logs/live-testing-20260701-141831/curated/amp-sample-*.json`](file:///d:/Phase2_Xbrain/final/tf4-cdo04-repo/evidence/logs/live-testing-20260701-141831/curated/) |
 
Các bằng chứng cũ đã bị thay thế chỉ dùng để chẩn đoán:
 
```text
acceptance-50rps-*insecure*
acceptance-50rps-*domain-multiservice*
acceptance-50rps-*domain.log without demo tenant
CloudWatch tail/error captures from live-testing-20260701-141831
```
 
## 3. Bằng chứng kiểm tra trước khi chạy (Preflight evidence)
 
Nguồn: `preflight-post-apply-smoke-signed.log`.
 
| Kiểm tra (Probe) | Kết quả (Result) | Đánh giá (Verdict) |
|---|---:|---|
| `/health` | 200 | PASS |
| `POST /v1/ingest` không ký | 403 | PASS |
| `POST /v1/ingest` có ký | 201 | PASS |
| `POST /v1/predict` không ký | 403 | PASS |
| `POST /v1/predict` có ký | 200 | PASS |
| AMP query endpoint | Kết nối được (reachable) | PASS |
| Các dịch vụ ECS sau thời gian chờ | Ổn định (stable) | PASS |
| DLQ baseline | 652 tin nhắn có sẵn | caveat baseline |
 
## 4. Bằng chứng chạy tải và đẩy telemetry (Load and ingest evidence)
 
### 4.1 Ngưỡng chạy khói 2 phút (2m smoke gate)
 
Cấu hình chạy:
 
```text
URL=https://jljhxtkm7f.execute-api.us-east-1.amazonaws.com
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=2m
```
 
Kết quả thu được từ `k6-50rps-2m-summary.json`:
 
| Chỉ số (Metric) | Kết quả (Result) | Ngưỡng (Gate) |
|---|---:|---|
| HTTP requests | 5,999 | ok |
| RPS duy trì (Sustained RPS) | 49.894/s | ok |
| Độ trễ p95 (p95 latency) | 258.94 ms | < 1000 ms |
| Yêu cầu thất bại (Failed requests) | 0 | < 1% |
| Dropped iterations | 2 | caveat |
| Kiểm tra thành công (Checks) | 5,999 / 5,999 | pass |
 
### 4.2 Ngưỡng chạy tải chính thức 3 giờ 50 RPS (3h final 50 RPS gate)
 
Cấu hình chạy:
 
```text
URL=https://jljhxtkm7f.execute-api.us-east-1.amazonaws.com
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=3h
```
 
Kết quả thu được từ `k6-50rps-3h-summary.json`:
 
| Chỉ số (Metric) | Kết quả (Result) | Ngưỡng / Diễn giải (Gate / interpretation) |
|---|---:|---|
| HTTP requests | 539,974 | ~540k sustained ingest calls |
| RPS duy trì (Sustained RPS) | 49.9965/s | target met |
| Độ trễ p95 (p95 latency) | 256.19 ms | pass, < 1000 ms |
| Avg latency | 249.00 ms | ok |
| Max latency | 19.38 s | isolated driver/network spike |
| Yêu cầu thất bại (Failed requests) | 19 / 539,974 = 0.0035% | pass, < 1% |
| Kiểm tra thành công (Checks) | 539,955 / 539,974 = 99.9965% | pass |
| Dropped iterations | 27 | strict zero-drop caveat |
| k6 exit code | 99 | caused by strict dropped_iterations threshold |
 
Phát biểu trình bày với mentor (Mentor-facing wording):
 
```text
The 3-hour run sustained 50 RPS over 539,974 ingest requests with p95 latency 256 ms and a 0.0035% failed-request rate. Twenty-seven local k6 dropped iterations occurred over the 3-hour run; this is documented as a strict-threshold caveat and not hidden.
```
 
## 5. Cú pháp và ý nghĩa luồng dữ liệu (Telemetry path semantics)
 
Luồng chạy thực tế hiện tại (Current runtime path):
 
```text
producer/k6/service -> POST /v1/ingest
telemetry-api validates payload and updates in-memory Prometheus Gauge
ADOT sidecar scrapes http://localhost:8080/metrics every 15s
ADOT remote_writes scraped samples to AMP
prediction-worker query_range reads AMP
```
 
Phạm vi quan trọng:
 
```text
50 RPS k6 validates ingest API headroom.
It does not prove AMP stores 50 event samples/sec.
ADOT stores latest gauge snapshots per scrape interval, which is correct for 1-minute prediction buckets.
```
 
Cadence đẩy dữ liệu demo thông thường:
 
```text
3 services x 7 signals / 60s = 0.35 RPS
50 RPS = about 143x demo producer headroom
```
 
## 6. Bằng chứng dự đoán của AI (AI prediction evidence)
 
Truy vấn DynamoDB audit hiển thị các bản ghi thực tế của tenant `demo-tenant-001` đối với cả 3 dịch vụ canonical.
 
Các bản ghi dự đoán AI đầy đủ cửa sổ (complete-window) thành công mới nhất:
 
| Thời gian UTC (Time UTC) | Dịch vụ (Service) | Nguồn (Source) | Bằng chứng (Evidence) | Trạng thái AI (AI status) |
|---|---|---|---|---:|
| 2026-07-01T17:37:31.904208+00:00 | fraud-detector | AI_ENGINE | complete_window | 200 |
| 2026-07-01T17:37:32.860310+00:00 | payment-gw | AI_ENGINE | complete_window | 200 |
| 2026-07-01T17:37:34.677907+00:00 | ledger | AI_ENGINE | complete_window | 200 |
 
Tiến trình thay đổi bản ghi Audit trong quá trình chạy (Audit evolution):
 
```text
poll-01: STATIC_THRESHOLD_FALLBACK partial_window ai_status_code=0
poll-03: AI_ENGINE partial_window ai_status_code=200
poll-05: AI_ENGINE complete_window ai_status_code=200
final:   AI_ENGINE complete_window ai_status_code=200 for all 3 services
```
 
Điều này chứng minh cơ chế xử lý khoảng trống dữ liệu lúc khởi động (cold-start gap) hoạt động đúng và luồng AI được kích hoạt thành công sau khi cửa sổ dữ liệu trên AMP được lấp đầy.
 
## 7. Bằng chứng sức khỏe hệ thống lúc chạy (Runtime health evidence)
 
Đợt quét cuối cùng (Final poll):
 
| Kiểm tra (Check) | Kết quả (Result) | Đánh giá (Verdict) |
|---|---:|---|
| Dịch vụ ECS lỗi | 0 | PASS |
| SQS chính hiển thị/đang xử lý | 0 / 0 | PASS |
| Hàng đợi DLQ hiển thị/đang xử lý | 652 / 0 | unchanged baseline |
| Truy vấn tức thời AMP | 20 / 21 present | caveat |
| Các dòng audit mới nhất trong DynamoDB | 30 queried | PASS |
 
Các đợt quét trước đó ghi nhận AMP đạt 21/21 chỉ số. Đợt cuối cùng đạt 20/21 là một caveat truy vấn tại thời điểm quét (point-in-time), không phải lỗi của worker vì bản ghi audit cuối cùng vẫn ghi nhận đầy đủ trạng thái dữ liệu complete-window gửi cho AI_ENGINE.
 
## 8. Caveat về nhật ký hoạt động của Worker và AI Engine (Worker and AI Engine log caveat)
 
Các tập tin CloudWatch logs thu thập từ đợt chạy `live-testing-20260701-141831` không chứa thông tin hữu ích do quá trình thu thập gặp lỗi hoặc không phát sinh log cảnh báo.
 
Thay vào đó, sử dụng các tài liệu bằng chứng dưới đây để chứng minh trạng thái ĐẠT (PASS):
 
```text
k6 summaries
preflight smoke
ECS service state
SQS main/DLQ depth
AMP query responses
DynamoDB audit records
```
 
Không sử dụng log dịch vụ CloudWatch làm bằng chứng nghiệm thu cho đợt chạy này.
 
## 9. Bằng chứng bảo mật và cô lập tài nguyên (Security and isolation evidence)
 
Được xác thực qua mã nguồn, kiểm thử tự động và thiết kế smoke test:
 
| Bài thử | Trạng thái |
|---|---|
| `POST /v1/ingest` yêu cầu chữ ký API Gateway SigV4 | preflight unsigned 403, signed 201 |
| `POST /v1/predict` yêu cầu chữ ký API Gateway SigV4 | preflight unsigned 403, signed 200 |
| Từ chối yêu cầu thiếu `X-Tenant-Id` | covered by Telemetry API tests |
| Từ chối yêu cầu sai lệch tenant_id giữa header và body | covered by Telemetry API tests |
| Từ chối các nhãn chứa PII hoặc có cardinality cao | covered by Telemetry API tests |
| Cổng `/metrics` công cộng không được định tuyến | smoke/design coverage |
| Cô lập tenant chéo tài khoản | N/A in single sandbox |
 
## 10. Bằng chứng chi phí (Cost evidence)
 
Dữ liệu chi phí thực tế từ Cost Explorer bị trễ từ 24-48 giờ, nên đợt chạy cùng ngày chưa thể thể hiện toàn bộ chi phí phát sinh.
 
Phát biểu trình bày với mentor (Mentor-safe statement):
 
```text
Budget guardrail and cost breaker are configured. Cost Explorer snapshot is delayed supporting evidence. Projected monthly cost remains under $200 based on deployed resource sizing.
```
 
## 11. Bảng tổng hợp các ngưỡng nghiệm thu cuối cùng (Final gate table)
 
| Nhóm cổng nghiệm thu (Gate group) | Bằng chứng (Evidence) | Đánh giá (Verdict) |
|---|---|---|
| Kiểm thử đơn vị và hợp đồng (Unit/contract) | pytest previously passed: 155 passed, 1 warning | PASS |
| Smoke test API Gateway | `/health` 200, unsigned protected routes 403, signed routes pass | PASS |
| Khói ingest (Ingest smoke) | 2m 50 RPS, 5,999 requests, 0 failures | PASS with drop caveat |
| Tải ingest 3h (3h ingest load) | 539,974 requests, p95 256 ms, 19 failures, 27 drops | PASS with caveat |
| Bao phủ 3 services | `ledger`, `payment-gw`, `fraud-detector` | PASS |
| Đường dẫn AI (AI path) | `AI_ENGINE`, `complete_window`, `ai_status_code=200` | PASS |
| Logic lấp khoảng trống dữ liệu của worker (Worker gap logic) | fallback -> partial AI -> complete AI transition captured | PASS |
| Trạng thái hàng đợi chính và DLQ (DLQ/queue) | main queue 0/0, DLQ unchanged at 652 | PASS |
| Chốt chặn chi phí (Cost guard) | budget/cost breaker configured | PASS |
 
## 12. Các điểm hạn chế còn lại (Remaining caveats)
 
Không nói quá (overclaim) về các điểm sau:
 
```text
- 3h k6 was accepted despite 27 dropped iterations; not strict zero-drop k6 pass.
- 19 failed requests were observed; failure rate still passed the <1% gate.
- CloudWatch log collection did not yield useful service logs for this live run.
- Final AMP instant query was 20/21; previous polls were 21/21 and final audit was healthy.
- 50 RPS is ingest API headroom, not normal telemetry cadence and not AMP event persistence rate.
- 100 RPS acceptance was not rerun in this final evidence set.
- Cross-account tenant isolation is N/A in this single sandbox.
- Cost Explorer same-day actuals are delayed supporting evidence only.
```
 
## Các tài liệu liên quan
 
- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`../tests/README.md`](../tests/README.md)
- [`../evidence/README.md`](../evidence/README.md)
