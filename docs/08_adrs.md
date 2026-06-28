# Architecture Decision Records - CDO-04 · Task Force 4

<!-- Doc owner: CDO-04
     Status: Ongoing log W11-W12
     Format: 1 ADR per major decision. Append-only - không xóa ADR cũ. -->

> **ADR là gì**: Architecture Decision Record. File log mỗi quyết định kiến trúc quan trọng + lý do tại sao chọn cái đó, chứ không phải mấy phương án khác.
>
> Mục đích: sau này khi quay lại codebase, nhóm vẫn hiểu vì sao đã chọn hướng kiến trúc hiện tại.

## ADR writing rule

Viết ADR khi decision có ít nhất một trong các điểm sau:

- Có trade-off thật giữa nhiều phương án.
- Chi phí đổi hướng sau này cao.
- Có thể bị mentor hoặc panel hỏi: “Vì sao nhóm chọn hướng này?”
- Decision ảnh hưởng tới infrastructure, deployment, security, cost, observability hoặc AI integration.

Không cần ADR cho các quyết định nhỏ như naming convention, tên file hoặc format comment.

Khi một ADR cũ không còn áp dụng, không xóa ADR cũ. Chỉ cập nhật:

`Status: Superseded by ADR-NNN`

Sau đó append ADR mới ở dưới.


## Ghi chú quyết định hiện tại (2026-06-26)

ADR-011 là quyết định hiện tại đã được chấp nhận cho region, TSDB product, query language và metrics auth model. Mọi nội dung ADR cũ nhắc đến Singapore/`ap-southeast-1`, Amazon Timestream/Timestream for InfluxDB, InfluxDB tokens, Flux, `promql_evidence_reference` hoặc Timestream VPC endpoints chỉ được giữ làm ngữ cảnh lịch sử, trừ khi ADR-011 lặp lại rõ ràng. Khi triển khai hiện tại, phải xem các chi tiết đó là đã bị thay thế bởi AMP tại `us-east-1` với PromQL và IAM/SigV4.

## Snapshot quyết định hiện tại cho Terraform v1 (2026-06-27)

- Khu vực triển khai: `us-east-1`.
- Metrics backend: AMP với PromQL và SigV4.
- Metrics ingestion: ADOT/Prometheus Collector tự quản lý trên ECS; app-direct remote_write chỉ dùng nếu đã triển khai protobuf/Snappy/SigV4/retry.
- Compute: ECS Fargate Linux/x86, private tasks.
- Cổng vào public: một HTTPS ALB cho `/v1/ingest`, giới hạn bằng `allowed_ingress_cidrs` khai báo rõ; không có giá trị mặc định mở.
- Luồng AI: Prediction Worker -> ECS Service Connect -> AI Engine. Terraform v1 không tạo internal ALB.
- Networking: một NAT Gateway cùng S3/DynamoDB Gateway Endpoints; interface endpoints mặc định tắt.
- Deployment: ECS rolling deployment circuit breaker trong Terraform v1. ECS-native blue/green là post-MVP; CodeDeploy không thuộc v1.
- Cảnh báo: CloudWatch Alarms + SNS email.
- Ngoài phạm vi v1: Service Connect TLS/Private CA, WAF, bộ PrivateLink đầy đủ, multi-account, multi-region DR.

Với ADR-001 đến ADR-008, mọi nội dung về Timestream/Singapore chỉ là lịch sử. Không triển khai Timestream resources từ các ADR đó.

## Target

- Pack #1 / W11: ít nhất 3 ADR.
- Pack #2 / W12: ít nhất 5 ADR.

## Suggested ADR areas for CDO-04

Các ADR dự kiến cho CDO-04:

- ADR-001: Chọn SLO Early-Warning Control Plane làm platform angle.
- ADR-002: Chọn Balanced Prediction Mode.
- ADR-003: Chọn Fail-open Static Threshold Fallback.
- ADR-004: Chọn Timestream làm telemetry store và metric evidence source.
- ADR-005: Chọn ECS Fargate thay vì Lambda cho Telemetry API và Prediction Worker.
- ADR-006: Chọn EventBridge Scheduler + SQS + DLQ cho prediction orchestration.
- ADR-007: Chọn DynamoDB làm prediction decision audit store.
- ADR-008: Chọn 1 NAT Gateway + S3/DynamoDB Gateway Endpoints cho MVP networking.

---

## ADR-001 - Choose SLO Early-Warning Control Plane as CDO platform angle

- **Status**: Accepted
- **Date**: 2026-06-23

- **Context**:

  TF4 Foresight Lens cần giải quyết bài toán SRE miss SLO do capacity exhaustion diễn ra âm thầm. Client là một fintech mid-size đang vận hành nhiều microservice và đã gặp nhiều lần SLO miss trong 3 tháng gần đây do các dấu hiệu như RDS CPU tăng dần, SQS backlog tăng hoặc ALB connection chạm giới hạn.

  Client đã có Grafana, CloudWatch và Datadog trial. Vì vậy, vấn đề chính không phải là thiếu dashboard hoặc thiếu metric. Vấn đề là SRE thiếu một workflow cảnh báo sớm có thể phát hiện drift/capacity risk trước khi SLO breach, đồng thời đưa ra recommendation đủ cụ thể để hành động.

  Nhóm CDO-04 cần chọn một platform angle đủ khác biệt, phù hợp vai trò Cloud/DevOps và có thể defend được trong capstone.

- **Decision**:

  Nhóm CDO-04 chọn angle:

  **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**

  Platform sẽ không build thêm một dashboard mới. Thay vào đó, CDO platform sẽ orchestrate toàn bộ workflow cảnh báo sớm:

  - ingest telemetry từ 3 service demo
  - lưu metric time-series vào Amazon Timestream
  - chạy prediction orchestration theo cadence định kỳ
  - gọi AI endpoint `POST /v1/predict`
  - tạo warning có root cause, recommendation, confidence và evidence
  - ghi audit log vào DynamoDB cho mỗi prediction hoặc fallback decision
  - gửi alert qua CloudWatch/SNS
  - cung cấp CloudWatch dashboard làm visualization evidence
  - fail-open sang static threshold fallback nếu AI endpoint timeout hoặc unavailable
  - giữ cost trong budget khoảng $200/tháng

  Evidence model của platform được chia thành 3 lớp:

  | Evidence type | Service chính | Ý nghĩa |
  |---|---|---|
  | Metric evidence | Amazon Timestream | Dữ liệu metric gốc mà worker/AI dùng để đánh giá risk |
  | Visualization evidence | CloudWatch Dashboard | Biểu đồ giúp SRE xem nhanh tình trạng service |
  | Decision evidence | DynamoDB Audit Log | Bản ghi prediction/fallback decision đã được platform lưu lại |

- **Consequence**:

  - ✅ Platform giải quyết đúng pain của client: cảnh báo sớm trước SLO breach thay vì chỉ hiển thị dashboard.
  - ✅ CDO-04 có vai trò rõ ràng: telemetry pipeline, prediction orchestration, infrastructure, audit, fallback, observability và cost guard.
  - ✅ Timestream được dùng làm metric evidence source, CloudWatch làm visualization/operational layer, DynamoDB làm decision audit evidence.
  - ✅ Workflow hỗ trợ các hard requirement quan trọng: lead time ≥15 phút, recommendation cụ thể, audit every prediction call và fallback khi AI unavailable.
  - ✅ Dễ liên kết với các tài liệu khác: `01_requirements_analysis.md`, `02_infra_design.md`, `03_security_design.md`, `04_deployment_design.md`.
  - ✅ Có thể defend rõ ràng khi mentor hỏi vì sao nhóm không build another dashboard.
  - ⚠️ Platform phức tạp hơn dashboard-only approach vì cần scheduler, queue, worker, TSDB, audit store, alerting và fallback path.
  - ⚠️ Cần contract rõ với Team AI về request schema, response schema, timeout, auth, model version, baseline version và error handling.
  - ⚠️ Cần quản lý cost cẩn thận vì prediction cadence, Timestream query, CloudWatch Logs và ECS runtime đều có thể tăng cost nếu không có guardrail.
  - ⚠️ Cần test kỹ fallback path để tránh trường hợp AI lỗi làm mất monitoring hoàn toàn.

- **Alternatives considered**:

  - **Dashboard-centric monitoring**:

    Rejected because client already has Grafana, CloudWatch and Datadog trial. Building another dashboard does not solve the main problem: SRE needs early warning, actionable recommendation, audit and fallback.

  - **Raw TSDB pipeline only**:

    Rejected as standalone approach because a TSDB only stores and queries metrics. It does not provide prediction orchestration, alert routing, audit decision, fallback behavior or operational workflow for SRE.

  - **AI endpoint hosting only**:

    Rejected because CDO responsibility is not only to host the AI endpoint. The platform must integrate telemetry, prediction calls, evidence, audit, alerting, security, rollback and cost guard.

  - **Auto-remediation platform**:

    Rejected because TF4 scope is predict + recommend only. Manual approval by SRE is acceptable and safer for fintech operations. Auto-remediation would increase operational risk and is explicitly outside the MVP scope.

---

## ADR-002 - Chọn Balanced Prediction Mode cho prediction cadence và lookback window

- **Status**: Accepted
- **Date**: 2026-06-23

- **Context**:

  TF4 Foresight Lens yêu cầu platform cảnh báo sớm trước SLO breach tối thiểu 15 phút, đồng thời false positive rate không vượt quá 12% và drift catch rate đạt ít nhất 80%. Nhóm CDO-04 cần chọn prediction operating mode phù hợp cho MVP capstone.

  Nếu gọi AI prediction quá dày, platform có thể phát hiện rủi ro nhanh hơn nhưng sẽ làm tăng số lượng AI calls, Timestream queries, DynamoDB audit records, CloudWatch logs và nguy cơ false positive. Nếu gọi prediction quá thưa, platform tiết kiệm cost hơn nhưng có thể phát hiện gradual drift hoặc slow leak quá muộn.

- **Decision**:

  Nhóm CDO-04 chọn **Balanced Prediction Mode** làm default mode cho MVP.

  Default operating mode:

  | Item | Decision |
  |---|---|
  | Prediction cadence | Mỗi 5 phút |
  | Telemetry frequency | Mỗi 1 phút |
  | Lookback window | Default 120 phút gần nhất |
  | Lead time target | Tối thiểu >=15 phút, target 30 phút nếu có thể |
  | Service scope | 3 service tier-1 |
  | Metric scope | 3-5 leading metrics/service |
  | Alert behavior | High risk gửi alert ngay, medium risk ghi annotation/shared channel, low risk chỉ ghi audit |
  | Cost target | Giữ platform dưới khoảng $200/tháng |

  Prediction Worker sẽ query telemetry gần nhất từ Timestream, build input window, gọi AI endpoint `POST /v1/predict`, ghi audit record vào DynamoDB và publish alert khi risk level là high.

Telemetry frequency và prediction cadence là hai nhịp khác nhau: Telemetry API ghi metric vào Timestream mỗi 1 phút, còn Prediction Worker chỉ chạy prediction mỗi 5 phút bằng cách query lookback window mặc định 120 phút gần nhất.

- **Consequence**:

  - ✅ Balanced mode hỗ trợ hard requirement về cảnh báo sớm với lead time >=15 phút.
  - ✅ Cadence mỗi 5 phút tạo đủ cơ hội để phát hiện gradual drift mà không tạo quá nhiều AI calls.
  - ✅ Telemetry frequency 1 phút cung cấp signal window đủ chi tiết cho AI mà vẫn giữ prediction cadence ở mức tiết kiệm cost.
  - ✅ Lookback window 120 phút align với AI API Contract và cung cấp đủ context time-series cho baseline/drift analysis.
  - ✅ Cost dễ kiểm soát hơn high-sensitivity mode vì số lượng prediction jobs, Timestream queries và audit records ở mức vừa phải.
  - ✅ Nguy cơ false positive thấp hơn mode 1 phút vì platform không phản ứng quá nhanh với các spike ngắn hoặc noisy baseline.
  - ✅ Dễ giải thích và test trong capstone với 3 service và 4 scenario: gradual drift, sudden spike, slow leak, noisy baseline.
  - ⚠️ Balanced mode có thể phát hiện một số sudden spike chậm hơn cadence 1 phút.
  - ⚠️ Nếu service behavior biến động mạnh, cadence 5 phút vẫn có thể cần tune theo từng service.
  - ⚠️ Team phải đảm bảo Timestream query luôn filter theo `tenant_id`, `service_id` và time window để tránh tăng query cost.
  - ⚠️ Cadence cuối cùng có thể cần điều chỉnh sau khi AI contract và kết quả evaluation W12 rõ hơn.

- **Alternatives considered**:

  - **High-sensitivity mode, prediction mỗi 1 phút**:

    Rejected for MVP vì làm tăng AI calls, Timestream query volume, DynamoDB audit writes và CloudWatch logs. Mode này có thể phát hiện nhanh hơn nhưng dễ tăng false positive và cost, không phù hợp với budget $200/tháng và target FP <=12%.

  - **Cost-saving mode, prediction mỗi 10 phút hoặc lâu hơn**:

    Rejected as default vì có thể phát hiện gradual drift hoặc slow leak quá muộn. Với cadence 10 phút, platform có ít cơ hội hơn để cảnh báo SRE trước yêu cầu lead time tối thiểu 15 phút.

  - **Static threshold only**:

    Rejected as primary mode vì static threshold chỉ là fallback path, không phải prediction workflow chính. Client hiện tại đã gặp hạn chế với static threshold và alert fatigue.

  - **Adaptive cadence ngay từ MVP**:

    Rejected for MVP vì việc tự động thay đổi cadence theo risk level làm tăng độ phức tạp triển khai. Hướng này có thể xem là future improvement sau khi base workflow ổn định.
---

## ADR-003 - Chọn Fail-open Static Threshold Fallback khi AI endpoint unavailable

* **Status**: Accepted

* **Date**: 2026-06-23

* **Context**:

  TF4 Foresight Lens yêu cầu platform có khả năng cảnh báo sớm bằng AI prediction, nhưng hệ thống không được phụ thuộc hoàn toàn vào AI endpoint. Trong quá trình vận hành, AI endpoint `POST /v1/predict` có thể timeout, unavailable, trả lỗi `5xx`, `429`, hoặc response sai schema.

  Nếu CDO platform chỉ dựa vào AI endpoint, khi AI lỗi thì SRE sẽ mất hoàn toàn khả năng giám sát rủi ro capacity exhaustion. Điều này không phù hợp với yêu cầu của client vì các sự cố như RDS CPU tăng dần, SQS backlog tăng hoặc ALB connection spike vẫn cần được phát hiện ngay cả khi AI unavailable.

  Vì vậy, nhóm CDO-04 cần một fallback strategy an toàn, đơn giản, có thể test được và có thể audit được.

* **Decision**:

  Nhóm CDO-04 chọn **Fail-open Static Threshold Fallback**.

  Khi AI endpoint gặp lỗi, Prediction Worker sẽ không dừng monitoring. Thay vào đó, worker sẽ chuyển sang static threshold fallback theo từng service.

  Các trigger kích hoạt fallback:

  * AI endpoint timeout.
  * AI endpoint trả lỗi `5xx`.
  * AI endpoint trả `429` sau retry limit.
  * AI endpoint unavailable.
  * AI response sai schema hoặc thiếu field bắt buộc.
  * AI response không parse được.

  Fallback behavior theo từng service:

  | Service           | Fallback metrics                                    | Example fallback condition                                    |
  | ----------------- | --------------------------------------------------- | ------------------------------------------------------------- |
  | `payment-gateway` | ALB latency, HTTP 5xx, active connection, RDS CPU   | p95 latency cao, 5xx tăng, RDS CPU vượt ngưỡng                |
  | `ledger-service`  | RDS CPU, DB connection utilization, query latency   | DB CPU/connection tăng dần, query latency vượt baseline       |
  | `kyc-worker`      | SQS queue depth, oldest message age, worker timeout | Queue depth tăng, oldest message age cao, worker timeout tăng |

  Khi fallback được dùng, audit log phải ghi rõ:

  ```text
  prediction_source = static_threshold_fallback
  fallback_reason = ai_timeout | ai_5xx | ai_429 | ai_unavailable | ai_không hợp lệ_response
  ```

  Alert được tạo từ fallback phải vẫn có đủ thông tin tối thiểu:

  * `service_id`
  * `anomaly`
  * `severity`
  * `reasoning`
  * `recommendation.action_verb`
  * `recommendation.target`
  * `recommendation.from_to`
  * `recommendation.confidence`
  * `recommendation.evidence_link`
  * `prediction_source`
  * `fallback_reason`
  * `prediction_id`
  * `promql_evidence_reference`
  * `cloudwatch_dashboard_url`

  Ví dụ fallback alert:

  ```text
  Service: kyc-worker
  Risk level: high
  Prediction source: static_threshold_fallback
  Fallback reason: ai_timeout
  Root cause: SQS queue depth and oldest message age exceeded fallback threshold.
  Recommendation: Increase kyc-worker concurrency from 20 to 40.
  Evidence: metric evidence reference + CloudWatch dashboard URL
  ```

* **Consequence**:

  * ✅ Platform không bị mất monitoring hoàn toàn khi AI endpoint lỗi.
  * ✅ Đáp ứng yêu cầu fail-open/fallback để tránh ảnh hưởng uy tín khi AI không khả dụng.
  * ✅ SRE vẫn nhận được warning dựa trên các metric quan trọng như RDS CPU, SQS backlog, ALB latency và HTTP 5xx.
  * ✅ Fallback decision vẫn được audit trong DynamoDB, giúp truy vết rõ warning đến từ AI hay static threshold.
  * ✅ Cách này đơn giản hơn so với việc build model dự phòng hoặc multi-AI endpoint trong MVP.
  * ✅ Dễ test trong W12 bằng scenario “AI endpoint down”, “AI timeout” hoặc “AI không hợp lệ response”.
  * ✅ Phù hợp với nguyên tắc predict + recommend, không auto-remediation.
  * ⚠️ Static threshold fallback kém thông minh hơn AI prediction và có thể phát hiện drift muộn hơn.
  * ⚠️ Static threshold có thể tạo false positive nếu threshold chưa được tune tốt.
  * ⚠️ Cần định nghĩa threshold riêng cho từng service để tránh dùng một ngưỡng chung quá thô.
  * ⚠️ Fallback không thay thế AI prediction, chỉ là safety path khi AI unavailable.
  * ⚠️ Nếu threshold quá cao, fallback có thể bỏ sót gradual drift; nếu threshold quá thấp, fallback có thể gây alert fatigue.

* **Alternatives considered**:

  * **Fail-closed khi AI endpoint lỗi**:

    Rejected vì nếu AI lỗi mà platform dừng prediction hoàn toàn thì SRE mất giám sát rủi ro capacity exhaustion. Điều này trái với mục tiêu early warning và không phù hợp với fintech/SRE context.

  * **Retry indefinitely cho tới khi AI endpoint hồi phục**:

    Rejected vì retry vô hạn có thể làm nghẽn worker, tăng queue backlog, tăng cost và vẫn không tạo được warning kịp thời. Retry chỉ nên có giới hạn, sau đó fallback.

  * **Manual-only monitoring khi AI lỗi**:

    Rejected vì quay lại phụ thuộc hoàn toàn vào người trực dashboard, trong khi client đã nói vấn đề hiện tại là không ai có thể watch dashboard 24/7.

  * **Backup AI endpoint hoặc secondary model**:

    Rejected for MVP vì làm tăng độ phức tạp triển khai, deployment contract, cost và testing scope. Có thể xem là production hardening trong tương lai.

  * **Static threshold only cho toàn bộ platform**:

    Rejected as primary mode vì static threshold chỉ là fallback. Client cần prediction workflow có baseline/drift awareness và actionable recommendation, không chỉ alert theo ngưỡng cứng.

---
## ADR-004 - Chọn Amazon Timestream làm telemetry store và metric evidence source

* **Status**: Superseded by ADR-011

* **Date**: 2026-06-23

* **Context**:

  TF4 Foresight Lens cần xử lý dữ liệu telemetry dạng time-series cho nhiều service. Prediction Worker cần query dữ liệu theo `tenant_id`, `service_id`, `metric_type` và time window 120 phút gần nhất trước khi gọi AI endpoint `POST /v1/predict`. Telemetry được ingest với frequency chính thức mỗi 1 phút để tạo signal window đủ chi tiết cho 3-Sigma/AI prediction.

  Dữ liệu này không chỉ dùng để gọi AI, mà còn dùng làm **metric evidence** khi platform tạo warning. Khi SRE nhận được alert, họ cần biết warning dựa trên metric nào, trong time window nào và service nào đang có drift/capacity risk.

  Nhóm CDO-04 cần chọn một storage phù hợp cho time-series metrics, có khả năng query hiệu quả theo service/time window và không biến CloudWatch Dashboard thành source of truth của prediction data.

* **Decision**:

  Nhóm CDO-04 chọn **Amazon Timestream** làm:

  * primary telemetry store
  * primary metric evidence source
  * source of truth cho prediction input
  * nơi Prediction Worker query dữ liệu time-series trước khi gọi AI
  * nơi lưu telemetry samples với frequency 1 phút

  CloudWatch vẫn được sử dụng nhưng với vai trò khác:

  * CloudWatch Logs cho application logs
  * CloudWatch Metrics/Alarms cho operational monitoring
  * CloudWatch Dashboard cho visualization evidence
  * SNS integration cho alert routing

  DynamoDB được dùng để lưu decision audit, không dùng để lưu raw time-series metrics.

  Evidence model của platform:

  | Evidence type          | Service chính        | Vai trò                                       |
  | ---------------------- | -------------------- | --------------------------------------------- |
  | Metric evidence        | Amazon Timestream    | Dữ liệu metric gốc dùng cho prediction        |
  | Visualization evidence | CloudWatch Dashboard | Biểu đồ giúp SRE xem nhanh                    |
  | Decision evidence      | DynamoDB Audit Log   | Audit record của prediction/fallback decision |

  Timestream record nên có các dimension chính:

  ```text
  tenant_id
  service_id
  metric_type
  env
  region
  service_tier
  ```

  Query bắt buộc filter theo:

  ```text
  tenant_id
  service_id
  metric_type
  time window
  ```

  để tránh query quá rộng và kiểm soát cost.

  Telemetry ingest frequency mặc định:

  ```text
  every 1 minute per metric
  ```

* **Consequence**:

  * ✅ Timestream phù hợp với dữ liệu time-series và prediction workflow cần query theo time window.
  * ✅ Prediction Worker có thể lấy input window 120 phút gần nhất cho từng service trước khi gọi AI.
  * ✅ Telemetry sample mỗi 1 phút giúp AI có đủ data points trong lookback window đúng 120 phút theo AI API Contract.
  * ✅ Metric evidence rõ ràng hơn so với chỉ dùng dashboard screenshot.
  * ✅ Hỗ trợ mô hình evidence 3 lớp: Timestream metric evidence, CloudWatch visualization evidence, DynamoDB decision evidence.
  * ✅ Giúp tách rõ vai trò giữa telemetry store, dashboard và audit store.
  * ✅ Phù hợp với yêu cầu không dùng raw S3 làm primary metric store.
  * ✅ Có thể mở rộng cho 3 service demo và multi-tenant pattern bằng `tenant_id` + `service_id`.
  * ⚠️ Timestream cần query discipline. Nếu query không filter theo service/time window, cost có thể tăng.
  * ⚠️ Team cần định nghĩa schema metric rõ với AI team để tránh mismatch request payload.
  * ⚠️ CloudWatch vẫn cần tồn tại cho logs, alarms và dashboard, nên platform phải vận hành cả hai lớp.
  * ⚠️ Timestream query reference cần được map vào alert/audit để SRE truy vết evidence dễ hơn.

* **Alternatives considered**:

  * **CloudWatch Metrics as primary prediction store**:

    Rejected as primary telemetry store vì CloudWatch phù hợp hơn cho operational monitoring, alarm, logs và dashboard. Prediction workflow cần query window theo `tenant_id`, `service_id`, `metric_type` và time range linh hoạt hơn. CloudWatch vẫn được giữ làm operational visibility layer.

  * **Raw S3 storage only**:

    Rejected vì raw S3 không phù hợp làm primary metric store cho prediction workflow cần query time-series nhanh theo service/time window. S3 có thể dùng cho archive hoặc evidence export, nhưng không dùng làm telemetry store chính trong MVP.

  * **DynamoDB for time-series metrics**:

    Rejected vì DynamoDB phù hợp hơn cho decision audit log và key-value/query pattern theo `prediction_id`, `tenant_id`, `service_id`, time. Nếu dùng DynamoDB để lưu raw time-series metrics, schema và query pattern sẽ phức tạp hơn cho baseline/drift analysis.

  * **RDS/PostgreSQL for telemetry metrics**:

    Rejected vì relational database không phải lựa chọn tối ưu cho high-volume time-series telemetry. RDS phù hợp cho transactional data hơn, trong khi bài này cần time-series query và retention pattern.

  * **Prometheus/Grafana stack**:

    Rejected for MVP vì cần vận hành thêm stack monitoring riêng. Client đã có dashboard/monitoring context, trong khi CDO cần tập trung vào AWS-native platform, AI integration, audit, fallback và cost guard. Grafana có thể là optional visualization layer nếu kịp.
----
## ADR-005 - Chọn ECS Fargate cho Telemetry API và Prediction Worker

* **Status**: Accepted

* **Date**: 2026-06-23

* **Context**:

  CDO-04 cần triển khai hai workload chính cho platform: Telemetry Ingestion API và Prediction Worker. Telemetry API nhận telemetry từ các service demo, còn Prediction Worker xử lý job từ SQS, query Timestream, gọi AI endpoint `POST /v1/predict`, ghi audit log vào DynamoDB và publish alert khi risk level cao.

  Ban đầu Lambda là một lựa chọn hợp lý cho MVP vì traffic capstone thấp. Tuy nhiên client production context đang sử dụng ECS Fargate, và CDO platform cần thể hiện rõ năng lực DevOps như container deployment, task role, health check, rollback, autoscaling và CloudWatch Logs.

* **Decision**:

  Nhóm CDO-04 chọn **ECS Fargate** làm compute platform cho:

  * Telemetry Ingestion API
  * Prediction Worker

  Container image của các workload sẽ được lưu trong Amazon ECR. ECS task definition sẽ định nghĩa image, CPU/memory, environment variables, secrets, IAM task role và CloudWatch log group.

  Rollback sẽ thực hiện bằng cách revert ECS service về task definition revision ổn định trước đó.

* **Consequence**:

  * ✅ Align với client production environment đang dùng ECS Fargate.
  * ✅ Chuẩn hóa deployment bằng container workflow: Docker image, ECR, ECS task definition và ECS service.
  * ✅ Dễ chứng minh DevOps/CDO evidence: health check, service status, task logs, task role, rollback và autoscaling.
  * ✅ Phù hợp với cả API workload và worker workload.
  * ✅ Runtime linh hoạt hơn Lambda nếu worker cần query Timestream, retry AI call, validate schema, fallback và ghi audit.
  * ✅ Dễ liên kết với `04_deployment_design.md` về CI/CD, rollback và smoke test.
  * ⚠️ Fixed cost cao hơn Lambda cho traffic thấp.
  * ⚠️ Cần cấu hình thêm ALB, ECS service, task definition, networking và ECR.
  * ⚠️ Cần quản lý image version và rollback strategy rõ ràng.
  * ⚠️ Nếu không có cost guard, ECS always-on task có thể làm tăng monthly cost.

* **Alternatives considered**:

  * **Lambda + API Gateway**:

    Rejected as default vì Lambda rẻ và đơn giản cho MVP traffic thấp, nhưng ít align hơn với client production context. Lambda cũng ít thể hiện container deployment, task role, ECS health check và rollback bằng task definition.

  * **EKS**:

    Rejected vì EKS quá nặng cho capstone MVP. EKS cần quản lý cluster, node/pod security, ingress, RBAC và GitOps phức tạp hơn, trong khi bài không yêu cầu Kubernetes.

  * **EC2 self-managed containers**:

    Rejected vì cần quản lý server, patching, scaling và deployment thủ công nhiều hơn. Fargate phù hợp hơn với mục tiêu managed, ít vận hành hạ tầng thấp.

  * **Single monolithic service**:

    Rejected vì Telemetry API và Prediction Worker có lifecycle khác nhau. API nhận request, worker xử lý job async. Tách workload giúp deploy, scale và debug rõ hơn.

---

## ADR-006 - Chọn EventBridge Scheduler + SQS + DLQ cho prediction orchestration

* **Status**: Accepted

* **Date**: 2026-06-23

* **Context**:

  ADR-002 đã chọn Balanced Prediction Mode với prediction cadence mỗi 5 phút. Telemetry frequency đã chốt là mỗi 1 phút, nhưng prediction không chạy mỗi phút; Prediction Worker sẽ chạy mỗi 5 phút và query dữ liệu telemetry 120 phút gần nhất từ Timestream. CDO platform cần một cách ổn định để trigger prediction job định kỳ cho 3 service demo, đồng thời tránh coupling trực tiếp giữa scheduler và Prediction Worker.

  Prediction job có thể lỗi do AI timeout, Timestream query lỗi, DynamoDB audit write lỗi hoặc worker deployment issue. Vì vậy orchestration cần có retry boundary, queue visibility và DLQ để debug job lỗi.

* **Decision**:

  Nhóm CDO-04 chọn:

  * **EventBridge Scheduler** để trigger prediction theo cadence định kỳ.
  * **SQS queue** để chứa prediction jobs.
  * **DLQ** để lưu job lỗi sau khi vượt retry limit.
  * **ECS Fargate Prediction Worker** để consume SQS message và xử lý prediction workflow.

  Flow chính:

  ```text
  EventBridge Scheduler
      -> SQS prediction queue
      -> ECS Fargate Prediction Worker
      -> Timestream query
      -> AI POST /v1/predict
      -> DynamoDB audit log
      -> SNS/CloudWatch alert
      -> DLQ if processing repeatedly fails
  ```

  SQS message tối thiểu nên có:

  ```text
  tenant_id
  service_id
  prediction_window_start
  prediction_window_end
  lookback_window_minutes
  correlation_id
  prediction_mode
  ```

* **Consequence**:

  * ✅ Decouple scheduler và worker, giúp worker lỗi không làm mất lịch trigger.
  * ✅ SQS giúp buffer prediction jobs nếu worker tạm thời chậm hoặc deploy lại.
  * ✅ DLQ giúp debug job lỗi thay vì mất event âm thầm.
  * ✅ Phù hợp với cadence mỗi 5 phút của Balanced Prediction Mode.
  * ✅ Dễ kiểm soát retry, visibility timeout và failure handling.
  * ✅ Dễ scale worker theo queue depth nếu cần.
  * ⚠️ Kiến trúc phức tạp hơn direct cron gọi thẳng worker.
  * ⚠️ Cần monitor SQS queue depth, oldest message age và DLQ depth.
  * ⚠️ Cần idempotency để tránh duplicate prediction audit khi SQS redelivery.
  * ⚠️ Cần định nghĩa retry limit hợp lý để không retry vô hạn khi AI endpoint lỗi.

* **Alternatives considered**:

  * **Direct cron inside worker**:

    Rejected vì worker phải tự giữ lịch, khó scale nhiều worker và khó debug khi job bị miss. Nếu worker down, lịch prediction có thể bị mất.

  * **EventBridge Scheduler gọi trực tiếp AI endpoint**:

    Rejected vì CDO cần query Timestream, enrich payload, validate AI response, ghi audit log, fallback và alert. Gọi trực tiếp AI sẽ bỏ qua orchestration logic của CDO.

  * **Step Functions**:

    Rejected for MVP vì Step Functions mạnh cho workflow nhiều bước, nhưng tăng complexity và state management. EventBridge + SQS + Worker đủ cho prediction workflow hiện tại.

  * **Kinesis streaming**:

    Rejected vì bài này không cần real-time stream processing liên tục. Prediction cadence mỗi 5 phút phù hợp với scheduled batch/window-based processing hơn.

  * **Manual trigger only**:

    Rejected vì không đáp ứng yêu cầu 24/7 monitoring và early warning.
## ADR-007 - Chọn DynamoDB làm prediction decision audit store

* **Status**: Accepted

* **Date**: 2026-06-23

* **Context**:

  TF4 Foresight Lens yêu cầu mỗi prediction call phải được audit. Audit log cần ghi lại AI prediction hoặc fallback decision, bao gồm service nào được đánh giá, risk level, recommendation, confidence, evidence reference, model/baseline version và lý do fallback nếu có.

  Audit log là **decision evidence**, khác với metric evidence. Metric evidence nằm ở Timestream, còn audit log cần query theo `prediction_id`, `tenant_id`, `service_id` và time để phục vụ review, debugging và demo evidence.

* **Decision**:

  Nhóm CDO-04 chọn **DynamoDB** làm prediction decision audit store.

  DynamoDB audit record nên có các field chính:

  ```text
  prediction_id
  timestamp
  tenant_id
  service_id
  prediction_source
  anomaly
  severity
  reasoning
  recommendation.action_verb
  recommendation.target
  recommendation.from_to
  recommendation.confidence
  recommendation.evidence_link
  audit_id
  promql_evidence_reference
  cloudwatch_dashboard_url
  deployment_version
  baseline_version
  fallback_reason
  correlation_id
  ```

  Nếu alert cần `risk_level` hoặc `root_cause`, CDO derive từ `severity` và `reasoning`; không yêu cầu AI trả thêm field ngoài contract.

  Suggested key pattern:

  ```text
  PK = TENANT#<tenant_id>#SERVICE#<service_id>
  SK = TS#<timestamp>#PRED#<prediction_id>
  ```

  Optional GSI:

  ```text
  GSI1PK = PRED#<prediction_id>
  GSI1SK = TS#<timestamp>
  ```

  Audit retention mặc định cho MVP: **90 ngày**.

* **Consequence**:

  * ✅ DynamoDB phù hợp với audit record dạng key-value/document.
  * ✅ Query tốt theo tenant, service, timestamp và prediction_id.
  * ✅ Dễ bật encryption at rest và TTL retention.
  * ✅ Phù hợp với serverless/managed AWS-native platform.
  * ✅ Tách rõ decision evidence khỏi metric evidence.
  * ✅ Audit log không phụ thuộc CloudWatch Logs, tránh việc logs retention ngắn làm mất evidence.
  * ✅ Dễ dùng trong demo: tìm prediction_id để chứng minh warning đã được ghi lại.
  * ⚠️ Không phù hợp để lưu raw time-series metrics, nên Timestream vẫn cần tồn tại.
  * ⚠️ Cần thiết kế partition key tránh hot partition nếu số service/tenant tăng.
  * ⚠️ Cần đảm bảo worker ghi audit cả khi dùng AI và khi dùng fallback.
  * ⚠️ Cần tránh lưu PII hoặc payload metric quá lớn trong audit record.

* **Alternatives considered**:

  * **CloudWatch Logs only**:

    Rejected vì CloudWatch Logs phù hợp cho application logs, nhưng không tối ưu cho audit query theo prediction_id/service/time. Log retention cũng có thể ngắn hơn audit retention.

  * **S3-only audit log**:

    Rejected for MVP vì S3 phù hợp archive, nhưng query trực tiếp cho demo/debug kém tiện hơn DynamoDB. S3 có thể dùng làm long-term archive nếu cần.

  * **RDS/PostgreSQL**:

    Rejected vì audit record không cần relational query phức tạp. RDS tăng vận hành, connection management và cost so với DynamoDB.

  * **Timestream audit table**:

    Rejected vì Timestream nên dùng cho metric time-series evidence, không phải decision audit record. Tách store giúp rõ trách nhiệm và dễ defend hơn.

  * **No dedicated audit store**:

    Rejected vì TF4 yêu cầu audit every prediction call. Không có audit store riêng sẽ yếu về governance và evidence.

---

## ADR-008 - Chọn 1 NAT Gateway + S3/DynamoDB Gateway Endpoints cho MVP networking

* **Status**: Accepted

* **Date**: 2026-06-23

* **Context**:

  CDO platform chạy ECS Fargate task trong private subnet. Các task cần pull image từ ECR, ghi CloudWatch Logs, đọc secret, query Timestream, đọc/ghi SQS/DynamoDB và publish SNS. Có hai hướng chính: dùng NAT Gateway để private task đi ra AWS public service endpoints, hoặc tạo full VPC Interface Endpoints cho từng AWS service.

  Với capstone MVP, traffic thấp vì chỉ demo 3 service, prediction cadence mỗi 5 phút và synthetic load chỉ bật trong test window. Vì vậy fixed cost của nhiều interface endpoint có thể cao hơn lợi ích tiết kiệm data processing.

* **Decision**:

  Nhóm CDO-04 chọn MVP networking strategy:

  * 1 NAT Gateway cho private ECS task access ra các AWS service endpoints cần thiết.
  * S3 Gateway Endpoint.
  * DynamoDB Gateway Endpoint.
  * Không tạo full Interface Endpoints trong Pack #1.
  * ECR API/ECR Docker Interface Endpoints là production hardening option, không bắt buộc trong MVP vì ECS task có thể pull image qua NAT Gateway.

  Production hardening option:

  * ECR API Interface Endpoint
  * ECR Docker Interface Endpoint
  * CloudWatch Logs Interface Endpoint
  * Secrets Manager Interface Endpoint
  * KMS Interface Endpoint
  * SQS Interface Endpoint
  * SNS Interface Endpoint
  * Timestream Interface Endpoint
  * CloudWatch Monitoring Interface Endpoint nếu cần custom metrics private-only

* **Consequence**:

  * ✅ MVP networking đơn giản hơn và nhanh build hơn.
  * ✅ Cost thấp hơn full interface endpoint trong traffic capstone thấp.
  * ✅ S3 và DynamoDB Gateway Endpoints vẫn giúp giảm NAT data processing cho S3/DynamoDB traffic.
  * ✅ ECS private task vẫn có thể pull image từ ECR qua NAT Gateway.
  * ✅ Phù hợp budget khoảng $200/tháng.
  * ✅ Dễ explain trade-off giữa cost, simplicity và production hardening.
  * ⚠️ NAT Gateway là một dependency cho private task outbound traffic.
  * ⚠️ Không phải private-only access tuyệt đối tới toàn bộ AWS services trong MVP.
  * ⚠️ Nếu traffic AWS service tăng lớn, interface endpoint có thể kinh tế hơn.
  * ⚠️ Production environment có thể cần interface endpoint để đáp ứng compliance/private-only requirement.

* **Alternatives considered**:

  * **Full Interface Endpoints from MVP**:

    Rejected vì cần nhiều endpoints cho ECR, CloudWatch Logs, Secrets Manager, KMS, SQS, SNS, Timestream và CloudWatch Monitoring. Với 1-2 AZ, fixed hourly cost của nhiều endpoints có thể cao hơn 1 NAT Gateway trong capstone traffic thấp.

  * **No NAT and no endpoints**:

    Rejected vì ECS private task sẽ khó pull image từ ECR, ghi logs, đọc secrets và gọi AWS service APIs.

  * **Public subnet ECS tasks**:

    Rejected vì workload CDO nên chạy private subnet để giảm exposure. Public access nên đi qua ALB/API entry, không expose task trực tiếp.

  * **2 NAT Gateways for high availability in MVP**:

    Rejected for MVP vì tăng cost. Design có thể vẽ multi-AZ, nhưng MVP cost estimate dùng 1 NAT Gateway để cân bằng budget. Production có thể dùng NAT per AZ.

  * **S3/DynamoDB traffic through NAT only**:

    Rejected vì S3 Gateway Endpoint và DynamoDB Gateway Endpoint là lựa chọn tốt cho MVP, giúp giảm NAT data processing mà không cần full interface endpoint strategy.


---
## ADR-009 - Host AI Engine Service on ECS Fargate in Singapore

* **Status**: Superseded by ADR-011

* **Date**: 2026-06-25

* **Context**:

  Sau khi Team AI freeze `ai-api-contract.md`, `telemetry-contract.md` và `deployment-contract.md`, CDO cần đồng bộ hạ tầng theo contract liên nhóm. AI Deployment Contract xác định rằng **CDO tự host AI Engine trên platform của mình**, compute target là **ECS Fargate task**, service chạy trong private subnet và rollback bằng ECS task definition.

  Đồng thời region chính thức của CDO platform được chốt là `ap-southeast-1` (Singapore). Vì vậy CDO cần quyết định final về việc host AI Engine bằng ECS Fargate hay chuyển sang Lambda/container function để tối ưu chi phí.

* **Decision**:

  Nhóm CDO-04 chọn host **AI Engine Service trên ECS Fargate** trong cùng VPC/ECS platform với Telemetry API và Prediction Worker.

  Final compute model:

  ```text
  Telemetry Ingestion API  -> ECS Fargate
  Prediction Worker        -> ECS Fargate
  AI Engine Service        -> ECS Fargate
  ```

  Final AI serving path:

  ```text
  Prediction Worker
      -> ECS Service Connect service name
      -> POST /v1/predict
      -> AI Engine Service
  ```

  Final region:

  ```text
  ap-southeast-1 (Singapore)
  ```

  AI Engine sizing:

  ```text
  min 2 tasks, max 4 tasks
  0.5 vCPU / 1GB per task
  health check path: /health
  port: 8080
  ```

* **Consequence**:

  * ✅ Align trực tiếp với AI Deployment Contract: CDO host AI Engine, target ECS Fargate, private subnet, rollback task definition.
  * ✅ Giữ toàn bộ core runtime trên cùng container platform: Telemetry API, Prediction Worker và AI Engine.
  * ✅ Worker có endpoint nội bộ ổn định cho `POST /v1/predict`, không gọi task IP động và không đi qua internet/NAT.
  * ✅ ECS Service Connect cung cấp private service discovery/load balancing, target isolation qua ECS service và security group boundary rõ ràng cho Luồng AI.
  * ✅ Rollback thống nhất bằng ECS task definition revision và CodeDeploy/ECS service rollback.
  * ✅ CloudWatch Logs/Metrics/ECS service event cung cấp deployment và operations evidence rõ hơn cho capstone.
  * ✅ Tránh rủi ro cold start và Lambda packaging adapter cho FastAPI/NumPy trong thời gian W12.
  * ⚠️ Chi phí idle cao hơn Lambda container image vì AI Engine giữ tối thiểu 2 tasks chạy nền.
  * ⚠️ Singapore pricing làm budget all-ECS khá sát $200, nên cần cost guard nghiêm ngặt: giới hạn synthetic load, log retention, không giảm prediction cadence dưới 5 phút và không tạo full interface endpoint trong MVP.
  * ⚠️ Nếu sau MVP cần tối ưu chi phí, Lambda container image cho AI Engine có thể được đánh giá lại như future optimization, nhưng không phải final decision.

* **Alternatives considered**:

  * **AI Engine on Lambda container image**:

    Rejected for final MVP dù có lợi về idle cost. Lý do: lệch với AI Deployment Contract, cần thay đổi cách expose `/v1/predict`, có rủi ro cold start, packaging FastAPI/NumPy cho Lambda, và tạo deployment/rollback model khác với Telemetry API/Worker.

  * **External AI endpoint hosted by AI team**:

    Rejected vì Deployment Contract nói rõ mỗi CDO tự host engine trên platform riêng. External shared endpoint làm yếu ownership, network boundary và rollback control của CDO.

  * **EKS**:

    Rejected vì quá nặng cho capstone MVP, tăng control-plane cost và vận hành phức tạp hơn ECS Fargate.

  * **Single monolithic ECS service cho Worker + AI**:

    Rejected vì Worker và AI Engine có lifecycle, scaling trigger, health check và rollback khác nhau. Tách thành ECS services riêng giúp vận hành rõ hơn.

---

## ADR-010 - Finalize Amazon Timestream for InfluxDB as the TSDB in ap-southeast-1

* **Status**: Superseded by ADR-011

* **Date**: 2026-06-26

* **Context**:

  ADR-004 correctly captured the architectural requirement: CDO needs a managed TSDB/evidence source for tenant/service/time telemetry and 120-minute prediction windows. However, older wording used the broad name **Amazon Timestream**, which can be read as the LiveAnalytics database/table + SQL product flavor. The final regional plan is Singapore (`ap-southeast-1`), and Terraform should target the **Amazon Timestream for InfluxDB** flavor for regional viability and InfluxDB-compatible org/bucket/measurement/tags/fields semantics.

  This ADR does not delete ADR-004. It records the final product flavor and updates the cost consequence of the TSDB choice.

* **Decision**:

  CDO-04 finalizes **Amazon Timestream for InfluxDB in `ap-southeast-1`** as the TSDB for telemetry and metric evidence.

  Final TSDB model:

  ```text
  Organization: tf4-cdo04
  Bucket      : telemetry
  Measurement : service_metrics
  Tags        : tenant_id, service_id, env, region, service_tier, metric_type
  Fields      : value, optional unit/sample_count
  Query style : Flux with tenant/service/enabled-metric filters and 120-minute range
  Retention   : 90-day bucket retention target
  ```

  Older references to Amazon Timestream should be interpreted as the TSDB requirement unless they explicitly mention LiveAnalytics. New Terraform and security docs should use the InfluxDB flavor, store InfluxDB credentials/tokens in Secrets Manager, and protect the endpoint with private networking/security group controls. Do not use LiveAnalytics-style IAM data-plane examples for the InfluxDB write/query path.

* **Cost consequence**:

  AWS Pricing MCP recheck for `ap-southeast-1` shows:

  | Instance | Deployment | Hourly price | 730h monthly estimate |
  |---|---|---:|---:|
  | `db.influx.medium` | Single-AZ | **$0.142/hour** | **~$103.66/month** |

  Therefore the old generic **$5/month TSDB** assumption is không hợp lệ. `db.influx.medium` Single-AZ is the minimum viable managed InfluxDB option. With this option, the full always-on platform becomes about **$296.04/month** before ops buffer, so it no longer fits a strict **$200/month** budget.

* **Mitigation**:

  * Use `db.influx.medium` Single-AZ for capstone unless load tests prove it is insufficient.
  * Keep prediction cadence at 5 minutes and require Flux filters by tenant, service, enabled metrics and 120-minute window.
  * Run within the 2-week capstone/demo window where forecast is about **$148.02** instead of presenting the full-month estimate as budget-fit.
  * Prefer ARM64/Graviton for ECS images when compatible, but recognize this only reduces compute and does not offset the full TSDB instance cost by itself.
  * Teardown or stop non-demo environments outside test windows where feasible; do not disable audit/fallback to save cost.
  * If the environment must run always-on for a full month, request budget exception or funding credits rather than hiding the TSDB cost.

* **Consequences**:

  * Final docs and Terraform direction are region/product-specific: Amazon Timestream for InfluxDB in Singapore.
  * Data model aligns with InfluxDB org/bucket/measurement/tags/fields and Flux semantics.
  * Security posture is clearer: no public TSDB exposure; credentials in Secrets Manager; endpoint access controlled by SG/private network and TLS.
  * Cost defense changes materially. The platform is still valid architecturally, but the full always-on monthly estimate is above $200 without mitigation.

---

## ADR-011 - Adopt AMP in us-east-1 with x86 ECS Fargate for CDO-04

* **Status**: Accepted

* **Date**: 2026-06-26

* **Context**:

  ADR-004 captured the original need for a TSDB-backed metric evidence source, ADR-009 selected ECS Fargate AI serving in Singapore, and ADR-010 finalized Amazon Timestream for InfluxDB `db.influx.medium` in `ap-southeast-1`. After the cost review, that design no longer fits a full-month $200 always-on target because the managed InfluxDB instance alone costs about $103.66/month.

  The team has now accepted the migration path analyzed in `docs/amp_migration_cost_estimate.md`: move the CDO deployment decision to `us-east-1`, replace Timestream for InfluxDB with Amazon Managed Service for Prometheus (AMP), and keep ECS Fargate Linux/x86 as the compute target.

  This is a CDO platform decision, not a frozen AI contract change. The AI contracts remain compatible: `POST /v1/predict`, IAM SigV4, 1-minute telemetry, 120-minute `signal_window`, AI Engine on ECS Fargate min 2/max 4, p99/throughput/availability targets, audit and fallback behavior all remain unchanged. The AI deployment contract already defaults `AWS_REGION` to `us-east-1` and describes the engine as region-agnostic according to the CDO deployment region.

* **Decision**:

  CDO-04 adopts this final decision:

  ```text
  Region          : us-east-1 / US East (N. Virginia)
  Compute         : ECS Fargate Linux/x86
  Metrics backend : Amazon Managed Service for Prometheus (AMP)
  Luồng AI         : Prediction Worker -> ECS Service Connect service name -> POST /v1/predict -> AI Engine
  ```

  AMP replaces the InfluxDB model:

  | Previous model | Accepted model |
  |---|---|
  | InfluxDB org/bucket/measurement/tags/fields | AMP workspace with Prometheus metric names and labels |
  | Flux query | PromQL `query` / `query_range` |
  | InfluxDB read/write/admin tokens in Secrets Manager | IAM/SigV4 with scoped AMP permissions |
  | Fixed `db.influx.medium` instance-hour cost | AMP usage-based ingest/storage/query pricing |

  Telemetry write path should prefer ADOT Collector, Prometheus Agent, or another customer-managed collector that remote-writes to AMP. Direct application `remote_write` is allowed only if the app explicitly implements protobuf encoding, Snappy compression, SigV4 signing, batching, retry/backoff and request-size control.

* **Cost consequence**:

  With `us-east-1` + AMP + x86 Fargate, the accepted full-month estimate is:

  | Component group | Estimate/month |
  |---|---:|
  | ECS Fargate x86 | **$90.10** |
  | Public ingest ALB + 1 LCU | **$22.27** |
  | 1 NAT Gateway + ~12GB data | **$33.39** |
  | AMP workspace at current demo volume | **~$0.00** |
  | DynamoDB, EventBridge/SQS, S3, CloudWatch/SNS, Secrets/KMS, ECR | **~$12.40** |
  | **Full always-on estimate** | **~$158.16/month** |
  | **+20% operations buffer** | **~$189.79/month** |

  This brings the full-month x86 design under the hard $200/month target before and after buffer while preserving the deployable topology: public ingest ALB plus ECS Service Connect for private Worker → AI traffic. The cost guardrails focus on log volume, synthetic-load windows, PromQL scope, label cardinality and Service Connect proxy resource headroom.

* **Consequences and guardrails**:

  * ✅ Restores full-month hard-budget fit before and after buffer while keeping ECS Fargate, audit, fallback and private AI serving.
  * ✅ AMP default 150-day retention satisfies the ≥90-day telemetry retention requirement.
  * ✅ AMP is available in `us-east-1` and supports `remote_write`, `query`, and `query_range`.
  * ✅ IAM/SigV4 replaces long-lived InfluxDB data-plane tokens, and AI request verification remains in AI Engine middleware/sidecar because Service Connect does not natively verify SigV4 for custom HTTP services.
  * ⚠️ AMP is a metrics backend, not a raw event lake. The 50k events/sec design ceiling is valid only with bounded samples/event and controlled label cardinality.
  * ⚠️ Do not use high-cardinality labels such as `request_id`, `trace_id`, `prediction_id`, `user_id`, or raw endpoint paths.
  * ⚠️ Runtime PromQL must always filter by tenant, service, metric name and the exact 120-minute range.
  * ⚠️ PrivateLink for AMP (`aps-workspaces`) is a production hardening option; the MVP can keep NAT + S3/DynamoDB Gateway Endpoints for cost control.
  * ✅ Terraform có thể bắt đầu sau khi docs chốt quyết định ADR-011/Terraform v1 này và reviewer chấp nhận bản cập nhật source of truth.

## Related documents

- `docs/00_client_debrief.md` - client discovery summary and scope lock
- `docs/01_requirements_analysis.md` - requirements, constraints and open questions
- `docs/02_infra_design.md` - infrastructure design and component architecture
- `docs/03_security_design.md` - IAM, secrets, encryption and audit controls
- `docs/04_deployment_design.md` - CI/CD, rollback and deployment workflow