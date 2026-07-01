# Requirements Analysis - TF4 Foresight Lens · CDO04

## 1. Đề tài context

TF4 Foresight Lens giải quyết bài toán cảnh báo sớm cho Head of SRE tại một fintech mid-size đang vận hành khoảng 120 microservice. Trong 3 tháng gần đây, hệ thống miss SLO 7 lần do các dấu hiệu **capacity exhaustion** diễn ra âm thầm, ví dụ RDS CPU tăng dần, SQS backlog tăng nhiều lần, hoặc ALB connection chạm giới hạn trong traffic spike.

Client đã có Grafana, CloudWatch và Datadog trial. Vì vậy, vấn đề chính không phải là thiếu dashboard hay thiếu metric. Pain chính là SRE không có một workflow cảnh báo sớm đủ tin cậy để phát hiện drift/capacity risk trước khi SLO breach, đồng thời thiếu recommendation cụ thể để hành động kịp thời.

Nhóm CDO chịu trách nhiệm xây dựng platform hạ tầng để:

* ingest telemetry từ các service demo
* lưu time-series metrics trong telemetry store phù hợp
* gọi AI prediction endpoint theo cadence định kỳ
* tạo risk decision từ AI response hoặc fallback threshold
* ghi audit log cho mỗi prediction call
* gửi alert/evidence cho SRE
* đảm bảo security, cost guard và rollback/fallback behavior

Angle của nhóm:

**SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**

Platform của CDO không build thêm một dashboard mới. Platform biến telemetry + AI prediction thành một workflow vận hành có recommendation, evidence, audit log và fallback khi AI endpoint unavailable.

---

## 2. Infra non-functional requirements

| NFR                    | Target                                                                 | Justification                                                            |
| ---------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Service scope          | 3 tier-1 services                                                      | TF4 yêu cầu multi-service ít nhất 3 service                              |
| Demo services          | `payment-gw`, `ledger`, `fraud-detector`                      | Đại diện cho ALB-heavy, RDS-heavy và Queue-heavy capacity patterns       |
| Canonical service IDs   | `payment-gw`, `ledger`, `fraud-detector`                               | IDs được dùng bởi Terraform, AI baselines, k6, và final evidence |
| Prediction cadence     | Every 5 minutes                                                        | Balanced mode, cân bằng giữa lead time và cost                           |
| Telemetry frequency    | Every 1 minute                                                         | Granularity chính thức để ghi metric vào AMP và tạo signal window đủ chi tiết cho AI |
| Lookback window        | Default 120 minutes                                                     | Align với AI API Contract: `signal_window` phải chứa dữ liệu ≥120 phút gần nhất |
| Lead time              | Minimum ≥15 minutes, target 30 minutes if possible                     | Hard requirement của TF4                                                 |
| False positive rate    | ≤12%                                                                   | Hard requirement, tránh alert fatigue                                    |
| Drift catch rate       | ≥80%                                                                   | Hard requirement, chứng minh prediction workflow có giá trị              |
| Telemetry retention    | ≥90 days for design, MVP retention may be reduced for cost if approved | Cần time-series history để baseline/drift analysis                       |
| Audit log              | Every prediction call and fallback decision                            | Hard requirement về traceability/governance                              |
| Metric evidence        | AMP PromQL/query_range reference / saved query reference                     | AMP là primary metric evidence source                             |
| Visualization evidence | CloudWatch Dashboard first, Grafana optional                           | CloudWatch dùng cho operational view và demo evidence                    |
| Decision evidence      | DynamoDB audit record / `prediction_id`                                | DynamoDB lưu prediction/fallback decision                                |
| Security               | Encryption at rest/in transit, least privilege IAM                     | Minimum security controls cho fintech/SRE context                                |
| Fallback               | Static threshold fallback when AI endpoint unavailable                 | Fail-open để không mất monitoring khi AI lỗi                             |
| Cost                   | ≤ $200/month                                                           | Capstone budget constraint                                               |
| Deployment             | ECS Fargate for Telemetry API, Prediction Worker and AI Engine Service | Align với client production environment, AI Deployment Contract và DevOps evidence |
| Rollback               | ECS task definition rollback + config rollback + Terraform rollback    | Giảm rủi ro khi deploy lỗi                                               |
| Dashboard scope        | Annotation/evidence only, no new full dashboard product                | Client đã có dashboard, nhóm không build another dashboard               |

---

## 3. Differentiation angle

### 3.1 Angle chọn

**SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**

### 3.2 Why this angle

Client không thiếu dashboard hay raw metrics. Client đã có nhiều nguồn quan sát như Grafana, CloudWatch và Datadog trial, nhưng vẫn miss SLO vì:

* slow drift không bị static threshold bắt đủ sớm
* alert hiện tại đến muộn
* SRE thiếu recommendation cụ thể
* không có workflow audit/evidence rõ ràng cho prediction decision
* không có fallback path khi AI endpoint unavailable

Vì vậy, CDO chọn angle **control plane** thay vì chỉ build dashboard hoặc chỉ host AI endpoint.

Platform sẽ tập trung vào:

* telemetry ingestion
* time-series evidence
* prediction orchestration
* AI contract integration
* recommendation workflow
* audit log
* alert routing
* fallback threshold
* cost guard

### 3.3 Điều làm platform khác biệt

| Khác biệt                    | Giải thích                                                                                            |
| ---------------------------- | ----------------------------------------------------------------------------------------------------- |
| Không phải another dashboard | Dashboard chỉ dùng để xem evidence, không phải sản phẩm chính                                         |
| Không chỉ là TSDB            | AMP là metric evidence source, nhưng platform còn có scheduler, worker, audit, alert, fallback |
| Không auto-remediation       | Platform chỉ predict + recommend, SRE manual approval                                                 |
| Có fail-open fallback        | Nếu AI timeout/unavailable, worker chuyển sang static threshold fallback                              |
| Có audit decision            | Mỗi prediction/fallback decision được ghi vào DynamoDB audit log                                      |
| Có evidence 3 lớp            | AMP metric evidence, CloudWatch visualization evidence, DynamoDB decision evidence             |
| Có cost guard                | Platform phải vận hành dưới budget $200/tháng                                                         |

### 3.4 Trade-off chấp nhận

Platform phức tạp hơn một dashboard hoặc một serverless function đơn giản vì cần nhiều thành phần:

* EventBridge Scheduler
* SQS + DLQ
* Prediction Worker
* AMP workspace
* DynamoDB audit log
* SNS/CloudWatch alerting
* fallback logic
* IAM/security controls

Đổi lại, platform đáp ứng tốt hơn các requirement khó của TF4:

* lead time ≥15 phút
* recommendation cụ thể
* audit every prediction call
* fallback khi AI unavailable
* evidence link
* cost guard

### 3.5 Locked decision

* Locked by CDO PM review.
* Default mode: **Balanced mode**.
* Compute: **ECS Fargate Linux/x86**.
* Telemetry store: **Amazon Managed Service for Prometheus (AMP)**.
* Audit store: **DynamoDB**.
* Evidence model: **AMP + CloudWatch + DynamoDB**.
* AMP query model: **Prometheus metric names + bounded labels + PromQL**.
* Label guardrail: không dùng high-cardinality labels như `request_id`, `trace_id`, `prediction_id`, `user_id` hoặc raw endpoint path; claim 50k events/sec chỉ hợp lệ khi samples/event và active series được kiểm soát.

### 3.6 AI integration contract alignment

Các điểm đã được chốt với Team AI cho W12 integration:

| Item | Decision |
|---|---|
| AI endpoint | `POST /v1/predict` |
| Telemetry frequency | Every 1 minute |
| Prediction cadence | Every 5 minutes |
| Lookback window | Default 120 minutes |

CDO sẽ thu thập telemetry mỗi 1 phút và ghi vào Amazon Managed Service for Prometheus (AMP) qua collector/app `remote_write`. Prediction Worker chạy mỗi 5 phút, query dữ liệu telemetry **120 phút gần nhất** bằng PromQL `query_range`, sau đó gọi AI endpoint `POST /v1/predict`. Mốc 120 phút này align với AI API Contract vì `signal_window` thiếu dữ liệu 120 phút có thể bị AI trả `400 Bad Request`.

Lưu ý: **telemetry frequency** khác với **prediction cadence**. Telemetry frequency là tần suất ghi metric vào AMP, còn prediction cadence là tần suất worker gọi AI để tạo prediction decision.

---

## 4. Approach comparison

### 4.1 Candidate approaches

Nhóm CDO cân nhắc 3 hướng chính:

| Approach                        | Mô tả                                                                                 | Ưu điểm                                                                              | Nhược điểm                                                                                        | Decision               |
| ------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ---------------------- |
| Dashboard-centric monitoring    | Dùng CloudWatch/Grafana dashboard và alarm là chính                                   | Dễ demo, đơn giản, quen thuộc với SRE                                                | Không giải quyết gốc pain vì client đã có dashboard; thiếu prediction workflow, audit và fallback | Rejected               |
| Raw TSDB pipeline only          | Ingest metrics vào TSDB rồi để AI/query dùng dữ liệu                                  | Hợp với time-series data, tốt cho evidence                                           | Chỉ có storage, chưa thành operational workflow cho SRE                                           | Rejected as standalone |
| SLO Early-Warning Control Plane | TSDB-backed telemetry + scheduler + worker + AI prediction + audit + alert + fallback | Đáp ứng trực tiếp lead time, evidence, recommendation, audit, fallback và cost guard | Phức tạp hơn MVP dashboard/serverless đơn giản                                                    | Selected               |

### 4.2 Why selected approach is better

Hướng **SLO Early-Warning Control Plane** được chọn vì nó giải quyết đúng vấn đề của client: phát hiện capacity risk sớm và biến prediction thành hành động vận hành có kiểm chứng.

Nó cũng phù hợp với vai trò CDO vì nhóm chịu trách nhiệm về:

* hạ tầng chạy workload
* deployment workflow
* telemetry pipeline
* observability
* security
* rollback/fallback
* cost guard
* contract integration với AI team

### 4.3 Compute choice

Nhóm chọn **ECS Fargate** cho Telemetry Ingestion API và Prediction Worker.

Lý do:

* Client production context đang dùng ECS Fargate.
* Platform có cả API workload và worker workload.
* ECS giúp chuẩn hóa container workflow qua ECR, task definition, service deployment, task role và CloudWatch Logs.
* ECS dễ chứng minh DevOps evidence: health check, rollback, autoscaling, task logs, IAM task role.
* Lambda rẻ hơn cho traffic thấp, nhưng ít aligned hơn với production-like container platform của client.

### 4.4 Network cost decision

MVP chọn:

* 1 NAT Gateway
* S3 Gateway Endpoint
* DynamoDB Gateway Endpoint
* Không dùng full VPC Interface Endpoints trong Pack #1

Lý do:

* Capstone traffic thấp vì chỉ demo 3 service, prediction mỗi 5 phút và synthetic load chỉ bật trong test window.
* Full interface endpoints cho ECR, CloudWatch Logs, Secrets Manager, KMS, SQS, SNS, AMP có fixed cost cao hơn NAT trong traffic thấp.
* S3/DynamoDB Gateway Endpoints vẫn nên dùng vì không có hourly endpoint charge.

Production hardening có thể bổ sung interface endpoints nếu cần private-only access hoặc traffic AWS service đủ lớn.

---

## 5. Constraints

### 5.1 Technical constraints

* AWS only.
* Region chính thức: `us-east-1` (US East / N. Virginia).
* Compute platform: ECS Fargate Linux/x86 for CDO workloads.
* Service scope: 3 tier-1 services.
* Telemetry: infra metrics only, no PII, no custom business metrics.
* Storage: efficient time-series query required; raw S3 is not used as primary metric store.
* Audit: every prediction call and fallback decision must be logged.
* Fallback: static threshold fallback when AI endpoint unavailable.
* Deployment: all changes go through pull request and review.

### 5.2 Business constraints

* Budget target: approximately $200/month.
* Scope: Predict + recommend only.
* No auto-remediation.
* No new full web/mobile dashboard.
* No multi-region production deployment.
* No production traffic mirror.
* No 6-month historical dataset requirement.
* No cross-service root cause analysis in MVP.

### 5.3 Security constraints

* No secrets committed to Git.
* AI endpoint config stored in Secrets Manager or SSM; Worker → AI auth uses IAM SigV4, not API keys.
* IAM follows least privilege.
* DynamoDB audit log encrypted at rest.
* HTTPS/TLS for AI endpoint calls.
* CloudWatch Logs retention configured.
* Audit/fallback must not be disabled by cost guard.

### 5.4 Timeline constraints

* W11: requirements, infra, security, deployment design and ADRs must be ready for review.
* W12: build, integrate with AI endpoint, test scenarios, evidence and demo.
* Code freeze follows capstone W12 schedule.

---

## 6. Open questions

Các contract chính với Team AI đã được freeze trong W11/W12. Phần này chỉ giữ lại câu hỏi CDO implementation còn cần clarify; các điểm contract đã resolved không yêu cầu sửa frozen AI contracts.

### 6.1 Resolved/frozen contract points

* [x] Endpoint chính thức: `POST /v1/predict`.
* [x] Auth Worker → AI: IAM SigV4; W11 mock có thể optional `Authorization`, W12 final enforce.
* [x] Telemetry frequency: 1 phút.
* [x] Prediction cadence: 5 phút.
* [x] Lookback window: `signal_window` phải chứa ≥120 phút gần nhất.
* [x] AI response fields CDO lưu đúng contract: `anomaly`, `severity`, `reasoning`, `recommendation.action_verb`, `recommendation.target`, `recommendation.from_to`, `recommendation.confidence`, `recommendation.evidence_link`, `audit_id`.
* [x] CDO derive `risk_level`/`root_cause` từ `severity` và `reasoning`; không yêu cầu AI trả thêm field ngoài contract.
* [x] AI deployment: CDO host AI Engine như ECS Fargate service private subnet, health check `/health` port 8080, min 2/max 4 tasks.
* [x] Fallback: AI timeout/unavailable/invalid schema → static threshold fallback và vẫn ghi audit.

### 6.2 CDO implementation questions still open

* [ ] AI Engine SigV4 verifier sẽ implement bằng FastAPI middleware hay sidecar? ECS Service Connect không verify SigV4 natively, nên W12 final cần enforcement point rõ.
* [ ] Timeout hard limit cuối cùng của Worker là 2 giây hay giá trị khác sau khi đo p99 AI thực tế? Nếu đổi, cập nhật test report và fallback runbook.
* [ ] PromQL query_range output format chính xác mà Worker dùng để build `signal_window` sẽ được chuẩn hóa ở DTO nào?
* [ ] Evidence link do CDO tạo dạng CloudWatch dashboard URL, AMP query reference, hay S3 evidence snapshot link?
* [ ] Correlation ID/request ID sẽ do CDO generate hay AI generate?
* [ ] 50k events/sec load test sẽ dùng samples/event và label cardinality ceiling cụ thể nào?

---

## 7. Out of scope

Các hạng mục sau không thuộc phạm vi CDO MVP:

* Auto-remediation.
* Cross-service root cause analysis.
* Cost forecasting.
* Auto-retrain pipeline build.
* Multi-region deployment.
* Production traffic mirror.
* Business metrics.
* New mobile/web dashboard.
* PII ingestion.
* 99.99% availability target.
* More than 3 service demo unless mentor yêu cầu.
* Full enterprise compliance audit.

---

## 8. Acceptance summary

File này được xem là hoàn thành khi:

* Scope CDO rõ ràng.
* NFR có target và justification.
* Differentiation angle giải thích được vì sao không phải another dashboard.
* Có comparison giữa các approach và decision rõ.
* Constraints bao gồm technical, business, security và timeline.
* Open questions tập trung vào AI contracts.
* Có liên kết được sang `02_infra_design.md`, `03_security_design.md`, `04_deployment_design.md` và `08_adrs.md`.

---

## Related documents

* `docs/00_client_debrief.md` - client discovery summary and scope lock
* `docs/02_infra_design.md` - infrastructure architecture and component design
* `docs/03_security_design.md` - IAM, secrets, encryption and audit controls
* `docs/04_deployment_design.md` - CI/CD, rollback and deployment workflow
* `docs/08_adrs.md` - architecture decision records
