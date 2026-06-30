# Client Debrief — TF4 Foresight Lens

## 1. Summary

Sau buổi Client Discovery, nhóm CDO hiểu rằng vấn đề chính của Client không phải là thiếu dashboard hay thiếu metric. Client đã có Grafana, CloudWatch và Datadog trial, nhưng vẫn miss SLO vì các dấu hiệu **capacity exhaustion** diễn ra âm thầm và alert hiện tại đến quá muộn.

Các sự cố như RDS CPU tăng dần, queue backlog tăng nhiều lần, hoặc ALB connection chạm giới hạn thường không được phát hiện đủ sớm. Khi SRE nhận ra vấn đề thì user đã bị ảnh hưởng hoặc support ticket đã xuất hiện.

Vì vậy, nhóm CDO chọn angle:

**SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**

Platform của nhóm không chỉ host AI endpoint và không build thêm một dashboard mới. Platform biến telemetry + AI prediction thành một workflow vận hành cho SRE, bao gồm:

* per-service telemetry policy
* per-service baseline
* prediction orchestration
* warning có recommendation
* Timestream metric evidence
* CloudWatch visualization evidence
* DynamoDB audit log
* fallback khi AI endpoint unavailable
* alert routing
* cost guard dưới budget $200/tháng

One-liner:

> Không phải another dashboard. Không phải chỉ TSDB. Nhóm CDO build control plane để biến telemetry + AI prediction thành quyết định vận hành có recommendation, metric evidence, audit và fallback.

---

## 2. Scope đã chốt

### 2.1 Demo services

Nhóm CDO chọn 3 service tier-1 sau cho demo:

| Service           | Lý do chọn                                                   | Capacity pattern                |
| ----------------- | ------------------------------------------------------------ | ------------------------------- |
| `payment-gw` | Ảnh hưởng trực tiếp tới giao dịch/revenue                    | ALB-heavy + RDS-heavy           |
| `ledger`  | Ghi nhận giao dịch/sổ cái, ảnh hưởng tính đúng đắn tài chính | RDS-heavy / DB connection-heavy |
| `fraud-detector`      | Ảnh hưởng onboarding, xử lý hồ sơ qua queue                  | Queue-heavy                     |

> Canonical runtime service IDs: `payment-gw`, `ledger`, `fraud-detector`. Legacy discovery names were normalized after contract freeze; see `contracts/addendum-2026-06.md`.

Ba service này đại diện cho ba dạng capacity risk khác nhau:

* `payment-gw`: traffic spike, latency, ALB/API pressure.
* `ledger`: database exhaustion, DB connection, query latency.
* `fraud-detector`: queue backlog, worker timeout, consumer throughput.

---

## 3. Metric cần theo dõi

### 3.1 `payment-gw`

Metric đề xuất:

* ALB request count
* ALB active connection count
* p95/p99 latency
* HTTP 5xx
* RDS CPU
* DB connection utilization

### 3.2 `ledger`

Metric đề xuất:

* RDS CPU
* DB connection utilization
* query latency
* p95 latency
* error rate

### 3.3 `fraud-detector`

Metric đề xuất:

* SQS queue depth
* oldest message age
* worker timeout
* worker concurrency
* consumer throughput
* ECS CPU/memory

### 3.4 Pending AI/CDO contract decision

Nhóm CDO cần confirm với Team AI:

* AI cần CDO gửi metric nào trong prediction request cho từng service?
* AI cần raw time-series window hay aggregated features?
* Granularity của metric nên là 1 phút, 5 phút hay giá trị khác?
* Lookback window chính thức là 60 phút hay 120 phút?
* Payload có giới hạn size/batch size không?

---

## 4. Prediction operating mode

Nhóm CDO chọn **Balanced mode** làm default mode trong capstone.

### 4.1 Balanced mode

| Item               | Decision                                              |
| ------------------ | ----------------------------------------------------- |
| Lookback window    | 1–2 giờ gần nhất                                      |
| Prediction cadence | Mỗi 5 phút/lần                                        |
| Lead time target   | Cảnh báo trước 30 phút nếu có thể, tối thiểu ≥15 phút |
| Metric scope       | 3–5 metric quan trọng nhất/service                    |
| Service scope      | 3 service tier-1                                      |
| Budget target      | ≤ $200/tháng                                          |

### 4.2 Alert behavior

| Risk level  | Platform behavior                             |
| ----------- | --------------------------------------------- |
| High risk   | Gửi alert cho SRE qua SNS/Email/Slack webhook |
| Medium risk | Ghi dashboard annotation hoặc shared channel  |
| Low risk    | Ghi audit log, không alert gấp                |

### 4.3 Lý do chọn Balanced mode

Cost-saving mode gọi prediction thưa hơn, ví dụ mỗi 10 phút, giúp tiết kiệm cost nhưng có thể phát hiện gradual drift chậm, không phù hợp với yêu cầu cảnh báo sớm.

High-sensitivity mode gọi prediction dày hơn, ví dụ mỗi 1 phút, giúp phát hiện nhanh hơn nhưng tăng chi phí, tăng số lượng audit log/query và có thể làm false positive cao hơn.

Balanced mode là lựa chọn hợp lý nhất vì cân bằng giữa:

* budget $200/tháng
* lead time ≥15 phút
* khả năng catch drift
* kiểm soát false positive
* khối lượng build phù hợp với capstone

---

## 5. Warning format

Warning tối thiểu cần có 3 thông tin:

1. Service nào đang có rủi ro.
2. Nguyên nhân chính.
3. Recommendation nên làm gì.

Ví dụ:

```text
Service: fraud-detector
Root cause: SQS queue depth tăng nhanh, oldest message age vượt baseline.
Recommendation: Increase fraud-detector concurrency from 20 to 40.
```

### 5.1 Expected AI response fields

Để CDO platform tạo warning đúng format, AI API response nên có tối thiểu:

```json
{
  "service_id": "fraud-detector",
  "risk_level": "high",
  "root_cause": "SQS queue depth increasing above baseline",
  "recommendation": "Increase fraud-detector concurrency from 20 to 40",
  "confidence": 0.86
}
```

Các field nên có thêm nếu AI team hỗ trợ:

```text
model_version
baseline_version
predicted_breach_in_minutes
reasoning_features
```

---

## 6. Recommendation format

Recommendation nên càng cụ thể càng tốt nhưng phải hợp lý và dựa trên evidence/metric.

Recommendation tốt nên có:

* action verb
* target
* from → to
* confidence nếu AI trả về
* metric evidence
* audit evidence

Ví dụ:

```text
Scale Aurora writer from db.r6g.large to db.r6g.xlarge.
```

```text
Increase fraud-detector concurrency from 20 to 40.
```

```text
Increase ECS desired task count for payment-gw from 2 to 4.
```

Nếu dữ liệu chưa đủ để đưa from → to chính xác, recommendation vẫn phải có action và target rõ ràng, ví dụ:

```text
Increase fraud-detector concurrency based on queue backlog growth and oldest message age.
```

---

## 7. Evidence model

Evidence giúp SRE kiểm chứng vì sao platform tạo warning. Với angle **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**, evidence không nên chỉ là một dashboard link. Evidence được chia thành 3 lớp:

| Evidence type          | Service chính        | Ý nghĩa                                                       |
| ---------------------- | -------------------- | ------------------------------------------------------------- |
| Metric evidence        | Amazon Timestream    | Dữ liệu metric gốc mà worker/AI dùng để đánh giá rủi ro       |
| Visualization evidence | CloudWatch Dashboard | Biểu đồ giúp SRE xem nhanh tình trạng service                 |
| Decision evidence      | DynamoDB Audit Log   | Bản ghi prediction/fallback decision đã được platform lưu lại |

### 7.1 Quyết định cho MVP

Primary metric evidence:

```text
Timestream query result / saved query reference
```

Operational visualization evidence:

```text
CloudWatch Dashboard URL
```

Decision audit evidence:

```text
DynamoDB audit record / prediction_id
```

Optional visualization nếu team kịp build:

```text
Grafana panel
```

### 7.2 Lý do chọn Timestream làm primary metric evidence

Timestream là nơi lưu time-series metrics dùng để Prediction Worker query window 1–2 giờ trước khi gọi AI `/v1/predict`. Vì vậy khi platform tạo warning, bằng chứng metric gốc nên trỏ về Timestream query hoặc query reference để chứng minh:

* metric nào tăng bất thường
* service nào bị ảnh hưởng
* time window nào được dùng để prediction
* baseline/drift được đánh giá trên dữ liệu nào
* AI hoặc fallback đã dựa trên dữ liệu nào để tạo risk decision

CloudWatch Dashboard vẫn được dùng để SRE xem biểu đồ nhanh, nhưng CloudWatch không phải source of truth của prediction input. Dashboard là lớp visualization, còn Timestream là nguồn metric evidence chính.

### 7.3 Alert high-risk nên chứa

Alert high-risk nên có:

```text
service_id
risk_level
root_cause
recommendation
confidence
prediction_id
timestream_query_reference
cloudwatch_dashboard_url
timestamp
prediction_source
```

### 7.4 Evidence relationship

```text
Timestream = metric evidence / dữ liệu gốc
DynamoDB Audit Log = decision evidence / AI hoặc fallback đã quyết định gì
CloudWatch Dashboard = visualization evidence / nơi SRE xem biểu đồ
Grafana = optional visualization nếu kịp
```

Dashboard không phải sản phẩm chính của nhóm. Dashboard chỉ là nơi SRE xem evidence trực quan. Source of truth cho metric evidence là Timestream.

---

## 8. CloudWatch vs Timestream decision

Nhóm CDO không chọn CloudWatch hoặc Timestream theo kiểu một trong hai. Hai service này có vai trò khác nhau trong platform.

### 8.1 Timestream role

Timestream là **primary telemetry store** và **primary metric evidence source**.

Timestream được dùng cho:

* lưu metric theo `tenant_id`, `service_id`, `metric_type`, `timestamp`
* query window 1–2 giờ cho Prediction Worker
* tạo input cho AI `/v1/predict`
* kiểm chứng metric gốc khi có warning
* hỗ trợ baseline/drift analysis

Timestream phù hợp với prediction workflow vì dữ liệu của bài là time-series và cần query theo tenant/service/metric/time window.

### 8.2 CloudWatch role

CloudWatch là **operational monitoring layer**.

CloudWatch được dùng cho:

* ECS/ALB/SQS operational metrics
* application logs
* alarms
* dashboards
* SNS alert integration
* runtime health monitoring
* evidence visualization cho SRE

CloudWatch phù hợp để SRE xem nhanh hệ thống có đang khỏe không, nhưng không phải nơi chính để worker query prediction input.

### 8.3 Decision

```text
Timestream is the source of truth for metric evidence.
CloudWatch is the operational visibility and visualization layer.
DynamoDB is the source of truth for prediction decision audit.
```

Bản tiếng Việt:

```text
Timestream là nguồn dữ liệu metric gốc dùng cho AI prediction và metric evidence.
CloudWatch là lớp quan sát vận hành: logs, metrics, alarms, dashboard.
DynamoDB là nơi lưu audit decision của từng prediction call.
```

---

## 9. Fallback behavior

Nếu AI endpoint `/v1/predict` timeout, unavailable, trả 5xx/429 quá retry limit, hoặc response sai schema, platform sẽ **fail-open fallback** sang static threshold để không mất giám sát hoàn toàn.

Fallback là service-specific:

| Service           | Fallback metric example                         |
| ----------------- | ----------------------------------------------- |
| `payment-gw` | ALB latency, 5xx, active connection, RDS CPU    |
| `ledger`  | RDS CPU, DB connection, query latency           |
| `fraud-detector`      | queue depth, oldest message age, worker timeout |

### 9.1 Fallback audit behavior

Khi fallback được kích hoạt, audit log phải ghi rõ:

```text
prediction_source = static_threshold_fallback
fallback_reason = ai_timeout | ai_5xx | ai_429 | ai_invalid_response
```

### 9.2 Pending CDO internal decision

Fallback threshold cụ thể cho từng service sẽ do Observability/Test owner draft trước, sau đó tune lại bằng synthetic test trong W12.

Initial demo threshold có thể dùng dạng:

```text
payment-gw:
- p95 latency > 1000ms trong 10 phút
- HTTP 5xx rate > 1%
- RDS CPU > 85% trong 10 phút

ledger:
- RDS CPU > 85% trong 10 phút
- DB connection utilization > 80%
- query latency p95 > 1000ms

fraud-detector:
- queue_depth > 5000
- oldest_message_age > 300s
- worker_timeout_rate > 1%
```

Các threshold trên là demo assumptions, không phải production final.

---

## 10. Audit log

Mỗi prediction call phải tạo audit log, bao gồm cả AI prediction và static fallback decision.

Audit fields đề xuất:

```text
prediction_id
timestamp
tenant_id
service_id
prediction_source
risk_level
confidence
root_cause
recommendation
timestream_query_reference
cloudwatch_dashboard_url
model_version
baseline_version
fallback_reason
```

Audit log phải:

* encrypted at rest
* có retention rõ ràng
* query được theo tenant/service/time
* không chứa PII
* không bị tắt khi cost guard kích hoạt

### 10.1 Audit retention decision

MVP chọn retention mặc định:

```text
90 ngày
```

Retention dài hơn sẽ được xem là production/compliance hardening nếu mentor hoặc contract yêu cầu.

---

## 11. Cost guard

Budget mục tiêu của platform:

```text
≤ $200/tháng
```

Cost guard policy mặc định:

| Budget level | Action                                                         |
| ------------ | -------------------------------------------------------------- |
| 50%          | Notify PM/Infra owner                                          |
| 80%          | Review synthetic load, log verbosity, Timestream query pattern |
| 100%         | Pause synthetic load test hoặc non-critical prediction jobs    |

Nguyên tắc:

* Không tắt audit log.
* Không tắt fallback.
* Không tăng prediction cadence xuống 1 phút nếu chưa có lý do test rõ ràng.
* Synthetic load chỉ bật trong test window.
* Log retention giữ mức hợp lý, ví dụ 14 ngày.
* Timestream query bắt buộc filter theo `tenant_id`, `service_id` và time window.

---

## 12. Open questions cần resolve với Team AI / Contract

### 12.1 Telemetry Contract

* [ ] AI cần raw time-series metrics hay aggregated features?
* [ ] Required telemetry schema gồm những field nào?
* [ ] Có bắt buộc các field `tenant_id`, `service_id`, `metric_type`, `timestamp`, `value`, `unit` không?
* [ ] Lookback window chính thức là 60 phút hay 120 phút?
* [ ] Metric granularity cần là 1 phút, 5 phút hay giá trị khác?
* [ ] Max payload size hoặc batch size cho mỗi prediction request là bao nhiêu?
* [ ] AI có yêu cầu CDO chuẩn hóa unit không? Ví dụ `latency_ms`, `cpu_percent`, `queue_depth`.

### 12.2 AI API Contract

* [ ] Endpoint chính thức có phải `POST /v1/predict` không?
* [ ] Request schema chính xác là gì?
* [ ] Response có bắt buộc trả về `service_id`, `risk_level`, `root_cause`, `recommendation`, `confidence` không?
* [ ] Response có trả `model_version`, `baseline_version`, `predicted_breach_in_minutes` không?
* [ ] Timeout/SLA của AI endpoint là bao nhiêu giây?
* [ ] AI sẽ trả error code nào khi overload hoặc unavailable? Ví dụ `429`, `503`, `504`.
* [ ] AI endpoint auth bằng gì: API key, IAM/SigV4, JWT hay private network?
* [ ] Skeleton endpoint có sẵn từ T5/T6 không để CDO test integration sớm?

### 12.3 Deployment Contract

* [ ] AI endpoint sẽ chạy ở đâu: Lambda, ECS Fargate, EKS hay service khác?
* [ ] CDO gọi AI endpoint qua public URL, private ALB, API Gateway hay VPC internal endpoint?
* [ ] Health check path là gì? Ví dụ `/health` hoặc `/ready`.
* [ ] AI endpoint có versioning không? Ví dụ `/v1/predict`.
* [ ] AI có yêu cầu secret/config nào CDO phải inject không?
* [ ] Khi AI deploy model mới, endpoint/schema có giữ backward compatibility không?
* [ ] Rollback của AI có ảnh hưởng tới CDO worker không?

### 12.4 Integration & Evaluation

* [ ] Lead time ≥15 phút sẽ đo theo telemetry timestamp, prediction timestamp hay alert timestamp?
* [ ] Precision/recall/F1 tính ở AI side, CDO side hay joint report?
* [ ] Confidence calibration evidence do AI team cung cấp, hay CDO cần lưu/log để support?
* [ ] AI response có trả `reasoning_features` hoặc metric gây rủi ro để CDO map sang Timestream evidence không?

---

## 13. CDO internal decisions cần chốt

Các quyết định này thuộc phạm vi CDO, không cần chờ Client hỏi lại trừ khi mentor yêu cầu.

| Decision                 | Default                                             |
| ------------------------ | --------------------------------------------------- |
| Compute                  | ECS Fargate for Telemetry API and Prediction Worker |
| Telemetry store          | Amazon Timestream                                   |
| Metric evidence source   | Timestream query result / saved query reference     |
| Evidence visualization   | CloudWatch Dashboard first, Grafana optional        |
| Decision audit evidence  | DynamoDB audit record / prediction_id               |
| Prediction orchestration | EventBridge Scheduler + SQS + DLQ                   |
| Audit store              | DynamoDB                                            |
| Alerting                 | SNS + CloudWatch Alarm                              |
| Network MVP              | 1 NAT Gateway + S3/DynamoDB Gateway Endpoints       |
| Fallback                 | Static threshold fallback when AI unavailable       |
| Cost guard               | 50/80/100 budget policy                             |
| Audit retention          | 90 days                                             |

---

## 14. Decisions locked after PM review

Sau PM review, nhóm CDO tạm lock các quyết định sau để các track khác bắt đầu draft:

* Angle: **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**
* Demo services: `payment-gw`, `ledger`, `fraud-detector`
* Prediction mode: **Balanced mode**
* Warning format: service + root cause + recommendation
* Recommendation format: action + target + from→to nếu evidence đủ + confidence + evidence reference
* Metric evidence source: Timestream query result / saved query reference
* Evidence visualization: CloudWatch Dashboard first, Grafana optional
* Decision evidence: DynamoDB audit record / prediction_id
* Fallback: static threshold fallback when AI endpoint unavailable
* Audit: every prediction call must be logged
* Cost guard: keep under $200/month, do not disable audit/fallback
* AI dependency: final schema, timeout, auth and deployment topology will be updated after AI contracts are reviewed

---

