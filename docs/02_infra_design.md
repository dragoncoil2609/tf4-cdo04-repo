# Infrastructure Design - Task force 4 · CDO SLO Early-Warning Control Plane

<!-- Doc owner: Nhóm CDO-04
     Status: Refined
     Word target: 1500-2500 từ -->

## 1. Architecture diagram

![Overall Architecture](assets/02_infra_design/overall-layout-group.png)

_Phân rã chi tiết theo block:_

| Block | Mô tả |
|---|---|
| ![API Entry](assets/02_infra_design/api-entry-block.png) | API Entry |
| ![Compute & Managed Services](assets/02_infra_design/compute-layer-and-aws-managed-services.png) | Compute & AWS Managed Services |
| ![Data Layer](assets/02_infra_design/data-layer-block.png) | Data Layer |
| ![Observability](assets/02_infra_design/observability-block.png) | Observability |

*Caption: Flow bắt đầu từ `payment-gateway`, `ledger-service` và `kyc-worker` gửi telemetry vào ALB; k6 chỉ tạo synthetic load cho cùng ingest path. Region triển khai final là `ap-southeast-1` theo AI Deployment Contract, với 2 AZ. Layout tách rõ trust boundary: external actors ở ngoài AWS account; public ALB/NAT và private ECS services nằm trong VPC; các regional managed services nằm ngoài VPC. ALB nằm ở public subnets để nhận HTTPS, còn ECS Fargate Telemetry API, Prediction Worker và **AI Engine** chạy trong private subnets của cùng ECS cluster với `assignPublicIp = DISABLED`. AI không còn là shared service/public dependency bên ngoài; worker gọi `POST /v1/predict` qua **internal target group trên ALB hiện có** (path-based routing: `/v1/ingest` → Telemetry API TG, `/v1/predict` → AI Engine TG), nên traffic prediction không đi qua internet/NAT. EventBridge Scheduler, SQS, **Amazon Timestream for InfluxDB**, DynamoDB, SNS, CloudWatch, S3, Secrets Manager và ECR là managed services nên được vẽ **ngoài VPC** hoặc sau private managed endpoint; Scheduler dùng execution role có quyền `sqs:SendMessage`, không chạy trong private subnet và không cần security group hoặc NAT. Luồng prediction được tách bằng Scheduler → SQS → Worker để ingestion không bị kẹt khi AI endpoint chậm hoặc lỗi. Mỗi lần dự đoán, worker lấy metric từ Timestream for InfluxDB bằng Flux query, đọc service policy, gọi AI internal `/v1/predict`, ghi audit vào DynamoDB, rồi đẩy evidence/alert qua CloudWatch/SNS. Nếu AI không phản hồi hoặc trả sai schema, worker chuyển sang static threshold fallback và vẫn ghi audit. Networking final dùng cost-optimized **1 zonal NAT Gateway** đặt trong một public subnet và được private subnets ở 2 AZ dùng chung cho outbound AWS API traffic chưa đi qua Gateway Endpoint; đây không phải “regional NAT” và không nằm trên đường gọi AI. S3 và DynamoDB đi qua **Gateway VPC Endpoints** với endpoint policy để giảm NAT data processing và giữ đường evidence/audit private. Full interface VPCE no-NAT đã bị loại cho baseline infra vì workload chỉ khoảng 12GB/tháng AWS API traffic; ở quy mô này fixed cost của nhiều interface endpoints × 2 AZ vẫn cao hơn 1 NAT Gateway và chỉ break-even ở mức traffic rất lớn. Traffic còn lại qua NAT được siết bằng HTTPS-only security group egress khi khả thi, IAM least privilege và application-level allowlist cho các AWS API cần gọi. Nếu InfluxDB endpoint không nhận write sau bounded retry, Telemetry API ghi raw payload có idempotency key vào S3 failure buffer để replay theo runbook; S3 buffer này không thay thế TSDB hot path. Timestream for InfluxDB không expose public TSDB endpoint cho tenant; access bị khóa bằng endpoint/SG controls, TLS, InfluxDB credentials lưu trong Secrets Manager và app-level tenant/service filters. Trade-off được chấp nhận của một zonal NAT Gateway là egress không HA tuyệt đối: nếu AZ chứa NAT lỗi, private task ở AZ khác có thể mất đường gọi public AWS APIs. Vì AI endpoint đã internal trong VPC, NAT failure không cắt đường Worker → AI. Quyết định final ưu tiên cost-security fit cho capstone: giữ 1 zonal NAT + S3/DynamoDB Gateway Endpoints, không triển khai full interface VPCE trong infra baseline.*

## 2. Component table

Giả định tính chi phí final: region `ap-southeast-1` theo AI Deployment Contract, 730 giờ/tháng, 2 AZ, 3 service demo, prediction mỗi 5 phút, app log retention 14 ngày, AI audit log retention 365 ngày, S3 raw failure buffer 7 ngày và telemetry/evidence/baseline retention tối thiểu 90 ngày. Đây là **chi phí platform baseline** cho demo scope, không phải chi phí phân bổ chính xác theo từng tenant. Giá chi tiết của network path được giải thích trong `vpce_vs_nat_cost_notes.md`; cost analysis tổng thể sẽ được chốt trong `05_cost_analysis.md`.

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| Tầng compute | ECS Fargate | Chạy 2 task cho Telemetry API, 1 task cho Prediction Worker và 2 task cho AI Engine trong cùng ECS cluster. Fargate phù hợp vì không phải quản lý EC2, có task role riêng, và chạy được API, worker, AI serving theo cùng mô hình container/private subnet. | **$112.46/tháng tại `ap-southeast-1`** = 5 task × 730h × (0.5 vCPU × $0.05056 + 1GB × $0.005530). |
| Cổng API | Application Load Balancer + ACM | ALB nhận telemetry từ 3 service demo và tải synthetic từ k6, kết thúc HTTPS rồi chuyển request vào ECS service. ACM certificate không tính phí. | **$24.24/tháng tại `ap-southeast-1`** = ALB $18.40 + 1 LCU trung bình $5.84. |
| Kho metric TSDB | Amazon Timestream for InfluxDB | Managed InfluxDB endpoint lưu telemetry theo org/bucket/measurement/tags/fields để worker query **đủ 120 phút** bằng Flux theo AI API Contract. | **$103.66/tháng cho db.influx.medium Single-AZ tại `ap-southeast-1`** = $0.142/giờ × 730h. Đây là minimum viable managed InfluxDB option cho baseline; estimate generic $5/tháng không còn hợp lệ vì Timestream for InfluxDB tính theo instance-hour; bucket retention target vẫn là 90 ngày. |
| Audit + service policy database | DynamoDB | Audit log là dữ liệu ghi nối tiếp, cần tra cứu nhanh theo tenant/service/time; service policy chứa metric allowlist, baseline, quota và fallback threshold. DynamoDB gọn hơn RDS cho key-value access pattern này. | **$0.10/tháng**: ~26k audit write/tháng + policy read nhỏ; read và storage rất nhỏ, nằm trong 25GB storage miễn phí. |
| Điều phối job | EventBridge Scheduler + SQS + DLQ | Scheduler tạo prediction job mỗi 5 phút; SQS tách worker khỏi độ trễ của AI; DLQ giữ job lỗi để debug. | **$0.05/tháng**: ~26k job/tháng, khoảng 3 SQS request/job; Scheduler gần như không đáng kể ở volume này. |
| Lưu trữ baseline + evidence + failure buffer | S3 + KMS | Lưu AI baseline JSON trong bucket KMS theo prefix `baselines/`, evidence/export và raw telemetry buffer khi Timestream for InfluxDB write fail; không dùng làm audit DB chính. | **$0.35/tháng**: giả định baseline/evidence/telemetry archive giữ tối thiểu 90 ngày, raw failure buffer giữ 7 ngày, request nhỏ. |
| Quan sát hệ thống | CloudWatch + SNS | Ghi app log task, custom metrics, alarm và dashboard; tách riêng AI audit log group KMS encrypted retention 365 ngày; SNS gửi alert high-risk. | **$8.00/tháng**: 1 dashboard ~$3, 10-12 alarm ~$1-2, log ingest/storage khoảng ~$3; AI audit volume demo nhỏ, SNS email dưới 1k notification miễn phí. |
| Bảo mật / cấu hình | Secrets Manager + KMS | Lưu internal endpoint/config của AI Engine, model config/secret nếu có, mã hóa DynamoDB/SQS/Logs bằng KMS, không hardcode credential. | **$3.40/tháng**: 3 secret × $0.40 + 2 KMS key × $1 + request nhỏ. |
| Kết nối private subnet | NAT Gateway + S3/DynamoDB Gateway Endpoints | Quyết định final: 1 zonal NAT Gateway đặt ở public subnet và dùng chung bởi private subnets ở 2 AZ cho outbound AWS API traffic không đi qua Gateway Endpoint; S3/DynamoDB dùng Gateway Endpoint miễn phí hourly. Full interface VPCE no-NAT không được chọn vì fixed cost cao hơn rõ rệt ở traffic ~12GB/tháng. | **$43.78/tháng tại `ap-southeast-1`** = 1 NAT × 730h × $0.059/h + ~12GB × $0.059/GB; S3/DynamoDB Gateway Endpoint không có hourly/data processing charge. |
| Container registry | Amazon ECR | Lưu private image cho Telemetry API, Prediction Worker và AI Engine; ECS execution role pull image khi deploy/replace task qua NAT cho ECR API/DKR và qua S3 Gateway Endpoint cho image layer path. | **~$0.10-$1/tháng** cho image demo nhỏ; đã nằm trong buffer vận hành 20%. |
| Bảo vệ public ingest endpoint + AI rate limit | ALB access log + app token bucket + source allowlist cho test traffic; AI contract-equivalent limiter | Public ALB chỉ expose telemetry ingest path. Với AI `/v1/predict`, nếu chưa thêm private API Gateway usage plan thì FastAPI middleware phải enforce đúng contract: 600 req/min/tenant, 6000 req/min global và trả `429 Retry-After`. AWS WAF không nằm trong infra baseline để giữ tổng cost dưới $200. | **$0 AWS fixed cost thêm** ngoài ALB/CloudWatch/S3 log đã tính; nếu thêm private API Gateway để match contract từng chữ, cần refresh cost riêng. |
| **Tổng baseline** |  | Network path dùng 1 zonal NAT + S3/DynamoDB Gateway Endpoints; TSDB dùng db.influx.medium Single-AZ. | **~$296.04/tháng tại `ap-southeast-1`** cho full always-on baseline. Thêm 20% buffer vận hành là **~$355.25/tháng**. Full always-on baseline không còn fit budget **$200/tháng** nếu không có mitigation như chạy capstone theo 2-week window, teardown ngoài giờ demo, ARM64/Graviton cho ECS, hoặc funding/budget exception. |

Cost guard:

- AWS Budget alarm tại 50%, 80%, 100% của **$200/tháng**.
- CloudWatch app log retention cố định 14 ngày; AI audit log group retention 365 ngày, KMS encrypted; S3 raw failure buffer 7 ngày, baseline/evidence/telemetry archive tối thiểu 90 ngày theo lifecycle policy.
- Synthetic load chỉ bật trong test window đã lên lịch.
- Flux query vào Timestream for InfluxDB bắt buộc có `tenant_id`, `service_id`, enabled metric và range 120 phút.
- Prediction cadence cố định 5 phút cho baseline; không dùng cadence 1 phút trong infra final.

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

Angle của nhóm là **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**. Điểm khác biệt không nằm ở việc dựng thêm dashboard, mà ở việc biến telemetry thành quyết định vận hành có thể kiểm chứng và audit được.

Client đã có Grafana, CloudWatch và Datadog trial. Vấn đề là dashboard không tự đưa ra cảnh báo sớm, còn threshold tĩnh thì dễ rơi vào hai cực: quá nhạy gây alert fatigue, hoặc quá trễ nên chỉ báo khi user đã bị ảnh hưởng. Vì vậy platform tập trung vào một luồng rõ ràng:

1. nhận metric từ 3 service demo;
2. lưu time-series metric vào Amazon Timestream for InfluxDB;
3. chạy prediction định kỳ mỗi 5 phút;
4. gọi AI endpoint `/v1/predict`;
5. tạo risk decision có root cause, recommendation và confidence;
6. ghi audit log cho mọi lần dự đoán;
7. gửi alert và evidence link cho SRE;
8. fallback sang static threshold nếu AI endpoint lỗi.

Dashboard chỉ là nơi xem evidence. Phần chính của CDO là control plane điều phối prediction, audit và fallback.

### 3.2 Vượt trội ở đâu (số liệu)

| Axis | My number | Competing angle estimate |
|---|---|---|
| Budget fit | **~$296.04/tháng** full always-on baseline tại `ap-southeast-1`, dùng khoảng **148.0%** budget $200; cần mitigation để defend budget | Dashboard-only có thể chỉ **$60-90/tháng**, nhưng không cover đủ prediction workflow, audit-per-call, fallback, evidence-link requirement và AI serving nội bộ |
| Cost / service | **~$98.68/service/tháng** baseline cho 3 service khi dùng db.influx.medium | EKS/self-hosted TSDB hoặc observability stack riêng dễ tăng compute + ops overhead, khó giữ dưới $200 nếu vẫn cần queue, audit, alert, fallback path và AI serving |
| Cost / prediction cycle | 3 services × mỗi 5 phút ≈ **25,920 prediction cycles/tháng**; baseline ≈ **$0.0114/cycle** | Dashboard-only không có prediction cycle/audit decision tương đương; static alarm rẻ hơn nhưng không tạo capacity recommendation có confidence/evidence |
| Contract fit | Region `ap-southeast-1`, AI ECS Fargate min 2/max 4, 120-minute signal window, IAM SigV4, S3 baseline, AI audit 365 ngày | Nếu dùng region/auth/window khác với AI contract thì W12 integration có thể fail dù infra chạy được ở demo local |
| Requirement coverage | Cover trực tiếp: **≥15 phút lead-time target**, per-service baseline, audit log mỗi prediction, static fallback, evidence link, encrypted stores | Dashboard-only fail pain point “không có người nhìn 24/7”; static threshold dễ alert fatigue hoặc miss slow drift; lakehouse/batch rẻ cho storage nhưng không hợp 5-min operational loop |
| Early-warning cadence | **5 phút** là balanced point: đủ nhanh để còn buffer cho yêu cầu cảnh báo trước ≥15 phút, nhưng chưa tăng query/job/audit volume quá mức | 1 phút nhanh hơn nhưng tăng noise/cost; 10 phút rẻ hơn nhưng giảm buffer cho yêu cầu cảnh báo sớm |
| Công vận hành | **2-3 giờ/tuần** nhờ dùng managed services: ECS Fargate, SQS, Timestream for InfluxDB, DynamoDB | EKS hoặc self-hosted TSDB có thể **6-10 giờ/tuần** cho node, storage, upgrade, retention và incident handling |
| Thời gian onboard service | **15-30 phút/service**: khai báo metric, baseline, fallback threshold, smoke test | Làm dashboard/alarm thủ công thường **30-60 phút/service** và dễ thiếu audit consistency |

Điểm cost của thiết kế này không phải là rẻ nhất tuyệt đối. Rẻ nhất tuyệt đối sẽ là dashboard-only hoặc vài CloudWatch alarm tĩnh, nhưng hai hướng đó không giải quyết đúng pain point client đã nêu: không có người nhìn dashboard 24/7 và threshold tĩnh dễ quá nhạy hoặc quá trễ. Vì vậy tiêu chí tối ưu là **cost-to-requirement coverage**. Sau khi chốt Amazon Timestream for InfluxDB tại `ap-southeast-1`, full always-on baseline tăng lên khoảng **$296.04/tháng** với db.influx.medium, vượt budget $200 khoảng **$96.04/tháng** trước buffer. ARM64/Graviton giảm ECS compute nhưng vẫn chưa đủ để đưa full always-on xuống dưới $200; mitigation thực tế là chạy đúng 2-week capstone window, teardown môi trường ngoài giờ demo/test, giữ synthetic load ngắn, hoặc xin budget exception. Dù giảm tải ở đâu, **không tắt audit/fallback**.

Balanced mode được chọn vì hợp với budget và yêu cầu lead time. Cadence 1 phút phát hiện nhanh hơn nhưng làm tăng Timestream for InfluxDB query, SQS job, audit write và alert noise. Cadence 10 phút rẻ hơn nhưng không còn nhiều buffer cho yêu cầu cảnh báo trước tối thiểu 15 phút.

### 3.3 Weakness chấp nhận

- **Phức tạp hơn dashboard-only**: cần scheduler, queue, worker, TSDB, audit DB và alert path. Nhóm chấp nhận điểm này vì fallback và audit log là hard requirement.
- **CDO platform phải host thêm AI serving capacity**: so với thiết kế cũ gọi endpoint ngoài, ECS cluster cần thêm AI Engine task, health check, logs, scaling rule và SG rule nội bộ. Đổi lại, đường gọi prediction private hơn, ít phụ thuộc internet/NAT hơn và match deployment contract mới.
- **Phụ thuộc AI response quality**: AI response bắt buộc được schema-validate trước khi tạo warning. Response thiếu các field theo AI contract như `anomaly`, `severity`, `reasoning`, `recommendation.action_verb`, `recommendation.target`, `recommendation.from_to`, `recommendation.confidence` hoặc `audit_id` bị xem là invalid schema và kích hoạt static threshold fallback; audit ghi `fallback_reason = ai_invalid_response`.
- **Static fallback có false positive**: fallback chỉ dùng khi AI unavailable hoặc response invalid. Audit record luôn ghi `prediction_source = static_threshold_fallback` để SRE biết đây không phải prediction từ model.
- **Chi phí được kiểm soát bằng guardrail cố định**: CloudWatch log retention giữ 14 ngày, S3 lifecycle tách raw buffer 7 ngày khỏi evidence/baseline 90 ngày, và mọi Flux query vào Timestream for InfluxDB bắt buộc filter theo `tenant_id`, `service_id`, enabled metrics và 120-minute window; cost guard bổ sung là teardown/non-demo shutdown vì full always-on db.influx.medium vượt $200/tháng.

## 4. Multi-tenant approach

### 4.1 Tenant model

- **Tenant ID format**: UUID v4
- **Header**: `X-Tenant-Id` bắt buộc cho mọi API call, nhưng không dùng header này làm nguồn xác thực duy nhất.
- **Auth rule**: tenant phải được derive/validate từ API key, JWT hoặc SigV4 principal. `X-Tenant-Id` chỉ là context header sau khi credential đã được verify.
- **Subscription tiers**: basic / pro / enterprise; ảnh hưởng quota, cadence và worker capacity.
- **Demo scope**: 1 tenant chính, 3 service tier-1: `payment-gateway`, `ledger-service`, `kyc-worker`.

Metric tối thiểu:

```text
tenant_id
service_id
metric_type
timestamp
value
unit
```

Audit record tối thiểu:

```text
prediction_id, timestamp, tenant_id, service_id, prediction_source,
anomaly, severity, reasoning,
recommendation_action_verb, recommendation_target, recommendation_from_to, recommendation_confidence,
evidence_link, audit_id, model_version, baseline_version
```

### 4.2 AI/CDO contract

- Endpoint path chốt cho tài liệu này: `POST /v1/predict`.
- Deployment topology: AI Engine chạy như ECS Fargate service trong **cùng ECS cluster/VPC** với CDO platform, không gọi qua public URL hoặc external shared service.
- Worker gọi AI qua **internal ALB** riêng cho AI Engine trong private subnets. Baseline Terraform **không tạo Route 53/private DNS** để tránh thêm một lớp chưa cần thiết cho MVP; Worker nhận internal ALB DNS từ Secrets Manager/SSM config và gọi route `/v1/predict` nội bộ. Nếu cần hostname ổn định như `ai-engine.cdo04.internal`, đó là production hardening/follow-up, không phải baseline.
- Auth giữa Worker và AI dùng **IAM SigV4** theo AI API Contract. Worker task role ký request tới `/v1/predict`; `Authorization` optional chỉ trong W11 mock testing, từ W12 final phải enforce. Không dùng API key/service token làm auth chính.
- Network layer: Worker SG gọi ALB SG; ALB SG chỉ forward `/v1/predict` đến AI Engine SG; không mở Worker SG → AI Engine SG trực tiếp và không expose AI endpoint public.
- Request phải mang `X-Tenant-Id`, `Authorization` SigV4 và tenant context đã verify; `signal_window[].tenant_id` phải match với header `X-Tenant-Id`.
- **SLA latency AI contract: P99 < 500ms, throughput 100 RPS aggregate, availability 99.5%.** Worker alarm khi AI p99 > 500ms (xem §6.1). CDO worker timeout hard limit 2 giây, sau đó fallback.
- Request body final phải chứa `signal_window` đủ **≥120 phút gần nhất** theo AI API Contract. Worker không gọi final AI endpoint nếu window ngắn hơn 120 phút.
- Trước khi gọi AI, Worker align dữ liệu thành 1-minute buckets liền mạch cho toàn bộ 120 phút; missing buckets phải forward-fill hoặc zero-fill theo metric policy. Nếu khoảng thiếu vượt ngưỡng policy, Worker không gọi AI và fallback với `fallback_reason = insufficient_signal_window`.
- Retry/error handling theo contract: `400` invalid input → không retry, fallback + engineering alert; `401` → refresh/re-sign credential và retry once; `429` → exponential backoff `1s → 2s → 4s`; `503/5xx/timeout` → static threshold fallback.
- Worker inject `context.deployment_version` từ **ECR image digest (SHA256)** của ECS task đang chạy, đọc qua ECS task metadata endpoint (`169.254.170.2/v4/metadata`) lúc startup, cached cho vòng đời task.
- CDO lưu audit record dùng **đúng tên field của AI response** (không mapping): `anomaly`, `severity`, `reasoning`, `recommendation.action_verb`, `recommendation.target`, `recommendation.from_to`, `recommendation.confidence`, `recommendation.evidence_link`, `audit_id`. Nếu alert cần `risk_level` hoặc `root_cause`, CDO derive từ `severity` và `reasoning`, không yêu cầu AI trả thêm field ngoài contract.

### 4.3 Isolation pattern

- **Data isolation**: dùng pooled model. Timestream for InfluxDB lưu `tenant_id`, `service_id`, `env`, `region` dưới dạng tags trong pooled bucket. DynamoDB dùng partition key có tenant/service để tránh query lẫn tenant.
- **Compute isolation**: basic/pro/enterprise trong capstone dùng chung ECS services với tenant-aware quota, policy và audit boundary để giữ cost dưới $200/tháng; không tách worker service riêng theo tenant trong baseline.
- **Lý do chọn pooled model**: đủ để chứng minh multi-tenant trong capstone mà không nhân đôi ALB, ECS cluster hay database cho từng tenant.

Tenant-aware rules:

- Mọi runtime query bắt buộc include `tenant_id`.
- Service phải thuộc tenant trước khi ghi metric hoặc query audit.
- Tenant A không đọc được audit/evidence của tenant B.
- Không đưa PII vào metric, audit key hoặc InfluxDB tags/fields.

### 4.4 DynamoDB audit database

Phần này mở rộng cho isolation pattern của template: audit record là nơi enforce tenant/service key design và tra cứu evidence theo prediction.

Access patterns:

| Access pattern | Cách query |
|---|---|
| Get prediction by `prediction_id` | Query GSI1 theo `PRED#<prediction_id>` |
| List predictions by tenant + service + time range | Query table chính theo `PK` và `SK BETWEEN` |
| List recent decisions by tenant | Query GSI2 theo tenant + time |
| Evidence lookup từ alert link | Alert chứa `prediction_id` hoặc `tenant_id/service_id/window_start` |

Key design:

```text
PK     = TENANT#<tenant_id>#SERVICE#<service_id>
SK     = TS#<window_start>#PRED#<prediction_id>

GSI1PK = PRED#<prediction_id>
GSI1SK = TS#<window_start>

GSI2PK = TENANT#<tenant_id>
GSI2SK = TS#<window_start>#SERVICE#<service_id>
```

Idempotency:

```text
prediction_id = hash(tenant_id, service_id, window_start, model_version, baseline_version)
```

- `PutItem` dùng conditional write: `attribute_not_exists(prediction_id)`.
- Worker chỉ delete SQS message sau khi audit write thành công.
- TTL CDO decision audit: 90 ngày cho baseline final. Lưu ý: đây là audit của CDO control plane, **không thay thế AI internal audit**.
- AI internal audit log theo AI API/Deployment Contract phải nằm trong CloudWatch Logs/S3 archive riêng, KMS encrypted, retention **365 ngày**.
- PITR bật ở final environment.
- KMS encryption bật; task role chỉ có quyền `PutItem`, `Query`, `GetItem` trên table/index cần dùng.

### 4.5 Service policy database

Phần này giữ service policy cùng tenant boundary với audit để worker và Telemetry API dùng chung baseline/fallback configuration có version.

Service policy được lưu tách logic với audit record trong DynamoDB để worker và Telemetry API cùng đọc một nguồn cấu hình có version. Mỗi tenant/service chỉ có một policy current; thay đổi policy phải tạo version mới để audit record truy vết được baseline và fallback rule nào đã được dùng.

Key design:

```text
PK = TENANT#<tenant_id>#SERVICE#<service_id>
SK = POLICY#CURRENT
```

Policy tối thiểu:

```json
{
  "tenant_id": "demo-tenant-001",
  "service_id": "kyc-worker",
  "enabled_metrics": [
    "sqs_queue_depth",
    "sqs_oldest_message_age_seconds",
    "latency_p95_ms"
  ],
  "prediction_interval_minutes": 5,
  "quota_tier": "basic",
  "baseline_version": "2026-06-23-v1",
  "fallback_rules": [
    {
      "metric_type": "sqs_queue_depth",
      "operator": ">",
      "threshold": 5000,
      "duration_minutes": 10,
      "risk_level": "high",
      "recommendation": "Increase kyc-worker concurrency from 20 to 40"
    }
  ]
}
```

Quyền truy cập: Telemetry API chỉ đọc `enabled_metrics` để enforce allowlist; worker đọc policy để áp baseline/fallback và ghi `baseline_version` vào audit; chỉ platform admin mới được cập nhật policy. Basic/Pro bị khóa cadence 5 phút, Enterprise chỉ được thay đổi qua approval, không qua tenant-facing API.

Baseline cadence và retrain trigger:

```text
Manual baseline train: 1 lần trước test window chính
Baseline review: weekly manual review cho từng service
Retrain / refresh trigger: FP rate >12%, catch rate <80%, service deploy làm đổi capacity profile,
traffic pattern thay đổi rõ rệt, hoặc static fallback threshold liên tục tạo false positive
ADR: ghi rõ trigger logic; infra lưu baseline_version trong service policy và audit record; baseline JSON thực tế lưu trong S3 KMS prefix `baselines/` theo AI Deployment Contract
```

### 4.6 Timestream for InfluxDB data model

Phần này bổ sung cách pooled tenant model được biểu diễn trong TSDB hot path. Timestream for InfluxDB không dùng database/table SQL kiểu Timestream for InfluxDB LiveAnalytics; model final dùng InfluxDB org/bucket/measurement/tags/fields và Flux query semantics.

InfluxDB layout:

| Khái niệm | Giá trị baseline | Ghi chú |
|---|---|---|
| Organization | `tf4-cdo04` | Scope quản trị/credential cho platform. |
| Bucket | `telemetry` | Bucket retention target **90 ngày** theo AI Telemetry Contract. Nếu cần archive dài hơn thì export sang S3, không thay hot path. |
| Measurement | `service_metrics` | Một measurement chung cho metric point của 3 service demo. |
| Tags bắt buộc | `tenant_id`, `service_id`, `env`, `region`, `service_tier`, `metric_type` | Tags dùng để filter nhanh; mọi runtime query phải có tenant/service/time. |
| Tags theo signal | `db_type`, `queue_name`, `cache_type` | Chỉ dùng khi signal cần label theo AI Telemetry Contract. |
| Fields | `value` numeric, optional `unit`/`sample_count` nếu cần | Field là dữ liệu đo; không dùng high-cardinality ID làm tag. |

Không dùng high-cardinality tags:

```text
request_id
trace_id
prediction_id
```

Metric fields align với telemetry contract signal names qua tag `metric_type`:

```text
api_latency_ms
cpu_usage_percent
memory_usage_percent
db_connection_pool_pct
queue_depth
cache_hit_rate_pct
active_connections
```

Signal-specific labels theo AI Telemetry Contract:

```text
db_connection_pool_pct -> db_type
queue_depth            -> queue_name
cache_hit_rate_pct     -> cache_type
```

`error_rate` và `oldest_message_age_seconds` vẫn có thể lưu để dashboard/fallback nội bộ, nhưng không được xem là required AI signals nếu chưa nằm trong contract.

Retention target:

```text
InfluxDB bucket retention: 90 ngày minimum theo AI Telemetry Contract
Worker lookback window: đúng 120 phút gần nhất trước mỗi AI call
S3 raw telemetry failure buffer: 7 ngày hoặc xóa ngay sau replay thành công
```

Flux query pattern bắt buộc:

```flux
from(bucket: "telemetry")
  |> range(start: -120m)
  |> filter(fn: (r) => r._measurement == "service_metrics")
  |> filter(fn: (r) => r.tenant_id == tenantId)
  |> filter(fn: (r) => r.service_id == serviceId)
  |> filter(fn: (r) => contains(value: r.metric_type, set: enabledMetrics))
  |> filter(fn: (r) => r._field == "value")
  |> aggregateWindow(every: 1m, fn: mean, createEmpty: true)
```

Không query toàn tenant/all services trong runtime path. Dashboard/evidence query dùng window nhỏ và filter service cụ thể.

### 4.7 Tenant onboarding flow

```text
1. POST /platform/v1/tenants (tenant_name, contact, tier)
2. Verify credential mapping với tenant_id
3. Tạo service policy cho payment-gateway, ledger-service, kyc-worker: enabled metrics, quota, baseline version, fallback rules
4. Cấu hình baseline và static fallback threshold theo từng service
5. Đăng ký metric tags/fields và enabled metric list trong Timestream for InfluxDB
6. Gán quota và prediction cadence mặc định 5 phút; tenant không tự tăng cadence
7. Smoke test: ingest metric → query TSDB → enqueue job → gọi worker → ghi audit
8. Callback tenant ready, mục tiêu < 30 phút
```

### 4.8 Noisy neighbor mitigation

| Guardrail | Basic | Pro | Ghi chú |
|---|---:|---:|---|
| Telemetry requests | 300 req/min | 1000 req/min | Token bucket ở application layer |
| Metric points | 5k points/min | 20k points/min | Chặn batch quá lớn |
| Payload size | 256KB/request | 512KB/request | Tránh log/query cost tăng đột biến |
| Service scope | 3 service | 5 service | Capstone chỉ cần 3 service |
| Prediction jobs | 1 job/service/5min | 1 job/service/5min | Không cho tenant tự tăng cadence |
| Lookback window | đúng 120 phút cho AI call | đúng 120 phút cho AI call | Theo AI API Contract; ngắn hơn 120 phút thì không gọi final AI endpoint |

Cost guard khi forecast gần $200/tháng: giữ cadence 5 phút, giảm synthetic load và log verbosity; không tắt audit/fallback.

## 5. Alternatives considered

### 5.1 Compute layer

| Phương án | Ưu điểm | Nhược điểm | Quyết định |
|---|---|---|---|
| Lambda + API Gateway | Rẻ khi traffic thấp, ít vận hành, scale tự động. | Worker query TSDB và gọi AI có thể chạy lâu; cold start làm p99 khó ổn định; không cùng container workflow với AI team. | Không chọn. Phù hợp ingestion đơn giản hơn là control plane có worker. |
| ECS Fargate + ALB | Chạy API, worker và AI serving bằng container, không quản lý EC2, hỗ trợ private subnet, task role, autoscaling và health check rõ ràng. | Có fixed cost cho ALB và task chạy nền; AI serving nội bộ làm baseline compute tăng. | ✅ **Chọn.** Đúng yêu cầu đề bài, match yêu cầu AI host trong ECS cluster và đủ production-like cho fintech workload. |
| EKS | Linh hoạt, mạnh cho platform lớn. | Quá nặng cho capstone; tăng cost và ops overhead. | Không chọn. Overkill cho 3 service demo. |

Nguyên tắc triển khai Fargate:

- Task chạy private subnet, `assignPublicIp=DISABLED`, network mode `awsvpc`.
- Telemetry API, Prediction Worker và AI Engine dùng cùng ECS cluster nhưng tách ECS service, task role, security group và autoscaling policy.
- ALB ở public subnet, HTTPS bằng ACM, HTTP redirect sang HTTPS cho telemetry ingest; path-based routing bổ sung `/v1/predict` target group trỏ đến AI Engine (chỉ accessible từ Worker SG nội bộ).
- Worker resolve AI Engine qua ALB internal DNS và gọi endpoint path `POST /v1/predict` qua AI Engine target group.
- Target group type `ip`; AI health check đúng Deployment Contract: path `/health`, port `8080`, interval 30 giây, healthy threshold 2 consecutive 200, unhealthy threshold 3 consecutive non-200, grace period 60-90 giây.
- Telemetry API và Prediction Worker có thể dùng ECS rolling deployment circuit breaker; riêng **AI Engine** dùng ECS Blue/Green với AWS CodeDeploy canary theo contract: 10% traffic trong 5 phút → 50% trong 5 phút → 100%.
- AI canary auto rollback khi error rate >1%, p99 latency >800ms, hoặc Capacity Exhaustion false/deviation >15%; rollback primary method là CodeDeploy về previous task definition, secondary là ECS service revert manual, target RTO <60 giây.
- Tách `executionRoleArn` để pull image/logs/secrets và `taskRoleArn` để ứng dụng gọi Timestream for InfluxDB endpoint, DynamoDB, SQS, SNS.
- Secret và config nhạy cảm đặt trong Secrets Manager hoặc SSM Parameter Store.

### 5.2 Database

| Phương án | Ưu điểm | Nhược điểm | Quyết định |
|---|---|---|---|
| RDS/Aurora | SQL mạnh, quen thuộc với transactional workload. | Audit log không cần relational join; phải quản lý connection, schema, backup và failover. | Không chọn. Nặng hơn nhu cầu audit. |
| S3-only audit log | Rẻ, giữ lịch sử lâu. | Lookup audit theo tenant/service/time chậm; khó demo near real-time evidence. | Không chọn làm audit DB chính; chỉ dùng S3 cho log/evidence export. |
| DynamoDB | Serverless, ghi append-heavy tốt, lookup nhanh theo key, KMS encryption, TTL, PITR. | Cần thiết kế partition key để tránh hot partition. | ✅ **Chọn.** Phù hợp nhất cho audit record mỗi prediction call. |

### 5.3 TSDB và luồng prediction

| Nhóm quyết định | Phương án | Ưu điểm | Nhược điểm | Quyết định |
|---|---|---|---|---|
| Metrics store | S3 metric lake | Rẻ cho dữ liệu lịch sử. | Không tối ưu query window 120 phút mỗi 5 phút. | Không chọn cho hot path; chỉ dùng archive/failure buffer. |
| Metrics store | Amazon Timestream for InfluxDB | Managed InfluxDB tương thích org/bucket/measurement/tags/fields, query Flux theo service/time tốt và khả dụng ở `ap-southeast-1`. | Có fixed instance-hour cost; db.influx.medium đã ~$103.66/tháng nên cần cost guard/teardown. | ✅ **Chọn** làm TSDB cho prediction và evidence. |
| Điều phối prediction | Scheduler gọi worker trực tiếp | Ít thành phần. | AI timeout có thể làm mất job hoặc block luồng xử lý. | Không chọn. |
| Điều phối prediction | EventBridge Scheduler → SQS → Worker | Có retry, DLQ, scale worker theo backlog, dễ demo failure path. | Thêm queue cần monitor. | ✅ **Chọn** cho control plane. |

## 6. Scaling strategy

| Thành phần | Sizing mặc định | Khi nào tăng | Giới hạn baseline |
|---|---|---|---|
| Telemetry API | 2 task × 0.5 vCPU / 1GB | CPU >70%, memory >75%, ALB p99 vượt target | Max 5 task |
| Prediction Worker | 1 task × 0.5 vCPU / 1GB | Queue age >2 phút, visible messages >20 trong 5 phút, backlog-per-task cao, worker timeout | Max 5 task |
| AI Engine | 2 task × 0.5 vCPU / 1GB | AI p95 >350ms trong 5 phút (early warning), AI p99 >500ms (SLO breach), 5xx tăng, CPU >70%, hoặc RequestCountPerTarget >80 RPS/task | Max 4 task theo AI Deployment Contract |
| Worker nâng cấp | 1 vCPU / 2GB | Flux query + AI call thường xuyên vượt timeout hoặc memory >75% | Ưu tiên nâng worker trước API vì bottleneck prediction nằm ở query + AI call path |

Scaling triggers:

| Component | Trigger | Action | Bounds baseline |
|---|---|---|---|
| Telemetry API | CPU >70%, memory >75%, hoặc ALB `RequestCountPerTarget > 200 req/min` trong 5 phút | Thêm 1 task | Min 2, max 5 |
| Prediction Worker - backlog | `ApproximateNumberOfMessagesVisible > 20` trong 5 phút | Thêm 1 worker task | Min 1, max 5 |
| Prediction Worker - lag | `ApproximateAgeOfOldestMessage > 2 phút` | Scale worker ngay và gửi SNS alert | Max 5 |
| Prediction Worker - scale-in | Queue trống và CPU <30% trong 10 phút | Giảm 1 worker task | Không dưới 1 task |
| AI Engine - early warning | p95 latency >350ms trong 5 phút hoặc RequestCountPerTarget >80 RPS/task | Gửi SNS, kiểm tra image/runtime, scale nếu p99 đang tăng | Min 2, max 4 |
| AI Engine - SLO breach | p99 latency >500ms hoặc 5xx >1% trong 5 phút | Thêm 1 AI task hoặc rollback AI version; gửi SNS nếu fallback rate tăng | Min 2, max 4 |

Ngoài autoscaling, theo dõi DLQ depth > 0, DynamoDB throttles, InfluxDB write failures/query error và AI fallback rate tăng bất thường.

Quy tắc xử lý SQS:

```text
Queue type: Standard SQS
Message retention: 4 ngày
DLQ retention: 14 ngày
Visibility timeout: 180 giây
Receive wait time: 20 giây long polling
maxReceiveCount: 5
Worker concurrency: 1-2 message/task
```

Message body:

```text
tenant_id
service_id
window_start
window_end
baseline_version
model_version
job_id
```

Worker flow:

```text
1. Receive message
2. Query Timestream for InfluxDB đủ 120 phút gần nhất
3. Align 1-minute buckets và forward-fill/zero-fill missing data theo metric policy
4. Nếu window <120 phút hoặc imputation vượt ngưỡng: static fallback, không gọi AI
5. Call AI /v1/predict bằng IAM SigV4 hoặc static fallback theo error matrix
6. Conditional write audit vào DynamoDB
7. Publish alert nếu severity/risk high
8. Delete SQS message cuối cùng
```

### 6.1 Observability triggers and evidence

Template yêu cầu scaling triggers; phần này giữ nguyên dashboard/alarm/evidence để làm trigger vận hành cho scale-out, fallback và replay.

Dashboard cần có các widget sau:

| Nhóm | Widget |
|---|---|
| ALB | Request count, 5xx, p99 latency |
| ECS | CPU, memory, running task count cho API và Worker |
| SQS | Visible messages, age of oldest message, DLQ depth |
| Prediction | Success count, failure count, fallback rate, AI latency |
| AI Engine | Internal target health, request count, p95 early warning, p99 SLO, 5xx, CPU/memory |
| Data stores | InfluxDB write/query errors, DynamoDB throttles/system errors |
| Audit | High-risk decisions gần nhất theo tenant/service |

Alarm tối thiểu:

| Alarm | Điều kiện gợi ý | Action |
|---|---|---|
| DLQ depth | `ApproximateNumberOfMessagesVisible > 0` | SNS |
| Queue age | `ApproximateAgeOfOldestMessage > 2 phút` | SNS + scale worker ngay |
| Fallback rate | fallback tăng bất thường trong 15 phút | SNS |
| AI internal target unhealthy | healthy task <2 hoặc ALB target group health check fail | SNS + rollback/redeploy AI service |
| AI latency SLA breach | AI p99 latency >500ms trong 5 phút (SLA từ AI contract) | SNS + review AI Engine task sizing; fallback rate tăng là leading indicator |
| Audit write failure | >0 trong 5 phút | SNS |
| InfluxDB write failures | >0 | SNS |
| ALB 5xx / platform p99 latency | platform/API p99 >800ms trong 5 phút hoặc 5xx >1% | SNS + rollback/canary abort nếu đang deploy |
| Budget | 50%, 80%, 100% của $200 | Email/SNS |
| Failure buffer age | S3 raw failure buffer object chưa replay sau >5 phút | SNS + chạy replay runbook |
| Partial evidence window | Prediction window có buffered telemetry chưa replay | Gắn cờ evidence partial và ưu tiên backfill |

Structured log tối thiểu:

```text
tenant_id
service_id
prediction_id
job_id
trace_id
prediction_source
risk_level
ai_latency_ms
fallback_reason
```

Evidence link trong alert trỏ đến CloudWatch Dashboard, audit record hoặc query/runbook tương ứng. Alert failure không làm mất audit; alert có thể replay từ audit record.

### 6.2 Security and network guardrails

Phần này là guardrail bổ sung cho scaling strategy: scale-out không được phá vỡ private-subnet posture, IAM boundary hoặc egress control.

Security group:

| Security group | Inbound | Outbound |
|---|---|---|
| ALB SG | 443 từ internet hoặc IP range demo; 80 chỉ redirect HTTPS; app port từ Worker SG (predict path nội bộ) | ECS API SG (ingest path); AI Engine SG (predict path) |
| ECS API SG | Chỉ từ ALB SG vào app port | HTTPS/443 tới AWS public service endpoints qua 1 zonal NAT; S3 failure buffer qua S3 Gateway Endpoint; DynamoDB không nằm trên API runtime path |
| Worker SG | Không mở inbound | HTTPS/443 tới SQS/Timestream for InfluxDB/SNS/Secrets Manager/CloudWatch/ECR control plane qua 1 zonal NAT; DynamoDB audit/policy qua DynamoDB Gateway Endpoint; app port tới ALB SG (predict path nội bộ) |
| AI Engine SG | Chỉ từ ALB SG vào port 8080; health check `/health` từ ALB target group | HTTPS/443 tới CloudWatch/Secrets Manager/ECR control plane qua 1 zonal NAT; S3 baseline bucket qua S3 Gateway Endpoint; không mở inbound từ Worker SG trực tiếp hoặc internet |

IAM role:

| Role | Quyền chính |
|---|---|
| ECS execution role | Pull image từ ECR, ghi CloudWatch Logs, đọc secret cần inject lúc start |
| Telemetry API task role | Timestream for InfluxDB write via Secrets Manager credential, CloudWatch metric/log, `s3:PutObject` chỉ vào failure-buffer prefix; không có quyền DynamoDB audit write vì API không tạo prediction |
| Worker task role | SQS receive/delete, Timestream for InfluxDB Flux query via Secrets Manager credential, DynamoDB `PutItem/Query/GetItem` audit + service policy, SNS publish, Secrets Manager read, ký IAM SigV4 request tới AI endpoint |
| AI Engine task role | `s3:GetObject` baseline bucket prefix `baselines/`, `kms:Decrypt` baseline/audit key, đọc model/config secret cần thiết, ghi CloudWatch app logs/custom metrics và AI audit logs; không có quyền đọc CDO audit table hoặc SQS prediction queue |
| EventBridge Scheduler execution role | Chỉ `sqs:SendMessage` vào prediction queue ARN; không có quyền truy cập VPC resource |
| Buffer replay role (break-glass) | Đọc failure-buffer prefix, ghi lại Timestream for InfluxDB; không có quyền đọc audit table hoặc secret không liên quan |

Public endpoint protection:

- HTTPS only, HTTP redirect sang HTTPS.
- ALB access logs bật và lưu S3.
- Failure buffer tách prefix, SSE-KMS, lifecycle 7 ngày; API task chỉ được ghi, replay role mới được đọc/replay.
- App token bucket và giới hạn IP nguồn k6/client demo là baseline protection cho public ingest endpoint.
- AWS WAF không nằm trong infra baseline để giữ tổng cost dưới $200; quyết định này đồng bộ với bảng cost ở §2.

Private subnet egress guardrails:

- NAT Gateway chỉ là outbound path, không được xem là trust boundary hay service/domain firewall.
- S3 và DynamoDB đi qua Gateway VPC Endpoints với endpoint policy; đường evidence/failure-buffer và audit/policy không cần NAT.
- Các AWS public service endpoints còn lại đi qua 1 zonal NAT Gateway final; SG egress giới hạn HTTPS/443.
- AI endpoint đi qua ALB internal target group trong VPC; Worker không cần NAT để gọi `/v1/predict`, chỉ cần SG rule Worker SG → ALB SG → AI Engine SG và ALB DNS nội bộ.
- ECS task roles giới hạn action/resource cụ thể; quyền truy cập thật sự được enforce bằng IAM và endpoint policy, không dựa vào NAT.
- AI internal endpoint URL (ALB DNS + path `/v1/predict`) lấy từ Secrets Manager hoặc SSM Parameter Store; worker validate host/path cố định trước khi gọi; không cho tenant/user input override URL tùy ý.
- Full interface VPCE no-NAT không nằm trong baseline final vì phân tích `vpce_vs_nat_cost_notes.md` cho thấy 10 interface endpoints × 2 AZ chỉ tối ưu cost khi traffic đạt multi-TB/tháng; workload CDO04 ước tính khoảng 12GB/tháng.

## 7. Failure modes + recovery

| Lỗi | Cách phát hiện | Cách khôi phục | RTO | RPO |
|---|---|---|---|---|
| Một ECS API/worker task crash | ECS service event, CloudWatch alarm trên task count hoặc log lỗi | ECS tự replace task; deployment circuit breaker rollback nếu bản mới lỗi | < 60s | 0 nếu producer retry; prediction job còn trong SQS |
| Mất một AZ | ALB target unhealthy, ECS thiếu task ở 1 AZ | ALB route sang AZ còn lại; ECS chạy task thay thế ở subnet khỏe | < 5min | < 1min |
| EventBridge Scheduler missed run | Không có job mới trong >10 phút | Alarm + manual enqueue/backfill window gần nhất | < 10min | Mất tối đa 1 prediction cycle nếu không backfill |
| AI internal endpoint timeout/down | Worker timeout, AI 5xx, internal target unhealthy, fallback-rate alarm | Chuyển sang static threshold theo service; audit ghi `prediction_source = static_threshold_fallback`; ECS rollback/redeploy AI service nếu bản mới lỗi | < 1 prediction cycle | 0, vì vẫn ghi audit fallback |
| AI response sai schema | Schema validation error | Fallback static threshold; audit `fallback_reason = ai_invalid_response` | < 1 prediction cycle | 0 |
| Tenant auth failure/spoofing | 401/403 tăng, tenant mismatch log | Reject request; không ghi metric/audit theo claimed tenant | Immediate | 0, vì request bị từ chối trước khi ghi |
| Prediction job lỗi lặp lại | SQS receive count vượt ngưỡng, DLQ depth > 0 | Retry theo redrive policy; sau `maxReceiveCount` chuyển DLQ để review payload/log | < 10min để isolate | Job lỗi nằm trong DLQ |
| Timestream for InfluxDB write/query failure | Rejected records, query error, worker log error | API retry bounded; nếu vẫn fail thì ghi raw payload + idempotency key vào S3 failure buffer và trả `202 Accepted`; nếu S3 cũng fail thì trả 5xx/429 để producer retry. Replayer chạy theo runbook để backfill TSDB; worker retry query với backoff. | 5-15min | Gần 0 nếu S3 buffer hoặc producer retry thành công |
| DynamoDB audit throttling/unavailable | DynamoDB throttle metric, worker `PutItem` error | SDK retry/backoff; chỉ delete SQS message sau khi audit write thành công | < 5min | Gần 0 nếu message vẫn còn trong SQS |
| Secrets/KMS access denied | Task startup/runtime decrypt error | Rollback task definition/role/key policy | < 15min | Không mất data, nhưng có thể delay prediction |
| SNS/alert channel failure | SNS delivery failure hoặc không nhận confirmation khi test | Audit vẫn là source of truth; sửa subscription rồi replay alert từ audit | < 15min | 0 cho audit, alert có thể delay |
| Cost guard triggered | Budget alarm hoặc custom cost metric | Giữ cadence 5 phút, giảm synthetic load/log verbosity, không tắt audit/fallback | Same day | 0 cho core audit |

Telemetry API trả `200/201` khi Timestream for InfluxDB write accepted. Nếu Timestream for InfluxDB vẫn fail sau bounded retry nhưng raw payload đã được lưu bền vững vào S3 failure buffer, API trả `202 Accepted` kèm request/event id để xác nhận sẽ replay; chỉ trả `5xx/429` khi cả Timestream for InfluxDB và S3 buffer đều thất bại. Failure buffer có alarm khi object age >5 phút và replay target trong 5-15 phút. Nếu prediction worker chạy trước khi telemetry buffered được replay, audit/evidence phải gắn cờ `evidence_status = partial_window` để SRE biết decision dựa trên window chưa đầy đủ. Prediction worker chỉ delete SQS message sau khi audit write thành công.

## Related documents

- [`03_security_design.md`](03_security_design.md) - Network Security §4 + IAM §5 + Data Security §6 expand on infra concerns
- [`04_deployment_design.md`](04_deployment_design.md) - IaC + CI/CD + GitOps cho infra này
- [`05_cost_analysis.md`](05_cost_analysis.md) - Platform baseline và mô hình phân bổ chi phí per-tenant dựa trên infra này
- [`08_adrs.md`](08_adrs.md) - Infra architecture decisions
