# Infrastructure Design - Task force 4 · CDO SLO Early-Warning Control Plane

<!-- Doc owner: Nhóm CDO-04
     Status: Draft
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

*Caption: Flow bắt đầu từ `payment-gateway`, `ledger-service` và `kyc-worker` gửi telemetry vào ALB; k6 chỉ tạo synthetic load cho cùng ingest path. Region triển khai final là `us-west-2` với 2 AZ. Layout tách rõ trust boundary: external actors ở ngoài AWS account; public ALB/NAT và private ECS services nằm trong VPC; các regional managed services nằm ngoài VPC. ALB nằm ở public subnets để nhận HTTPS, còn ECS Fargate Telemetry API, Prediction Worker và **AI Engine** chạy trong private subnets của cùng ECS cluster với `assignPublicIp = DISABLED`. AI không còn là shared service/public dependency bên ngoài; worker gọi `POST /v1/predict` qua **internal target group trên ALB hiện có** (path-based routing: `/v1/ingest` → Telemetry API TG, `/v1/predict` → AI Engine TG), nên traffic prediction không đi qua internet/NAT. EventBridge Scheduler, SQS, Timestream, DynamoDB, SNS, CloudWatch, S3, Secrets Manager và ECR là regional managed services nên được vẽ **ngoài VPC**; Scheduler dùng execution role có quyền `sqs:SendMessage`, không chạy trong private subnet và không cần security group hoặc NAT. Luồng prediction được tách bằng Scheduler → SQS → Worker để ingestion không bị kẹt khi AI endpoint chậm hoặc lỗi. Mỗi lần dự đoán, worker lấy metric từ Timestream, đọc service policy, gọi AI internal `/v1/predict`, ghi audit vào DynamoDB, rồi đẩy evidence/alert qua CloudWatch/SNS. Nếu AI không phản hồi hoặc trả sai schema, worker chuyển sang static threshold fallback và vẫn ghi audit. Networking final dùng cost-optimized **1 zonal NAT Gateway** đặt trong một public subnet và được private subnets ở 2 AZ dùng chung cho outbound AWS API traffic chưa đi qua Gateway Endpoint; đây không phải “regional NAT” và không nằm trên đường gọi AI. S3 và DynamoDB đi qua **Gateway VPC Endpoints** với endpoint policy để giảm NAT data processing và giữ đường evidence/audit private. Full interface VPCE no-NAT đã bị loại cho baseline infra vì workload chỉ khoảng 12GB/tháng AWS API traffic, trong khi 10 interface endpoints × 2 AZ tại `us-west-2` tạo fixed cost khoảng $146/tháng và chỉ break-even ở mức multi-TB/tháng. Traffic còn lại qua NAT được siết bằng HTTPS-only security group egress khi khả thi, IAM least privilege và application-level allowlist cho các AWS API cần gọi. Nếu Timestream không nhận write sau bounded retry, Telemetry API ghi raw payload có idempotency key vào S3 failure buffer để replay theo runbook; S3 buffer này không thay thế TSDB hot path. Trade-off được chấp nhận của một zonal NAT Gateway là egress không HA tuyệt đối: nếu AZ chứa NAT lỗi, private task ở AZ khác có thể mất đường gọi public AWS APIs. Vì AI endpoint đã internal trong VPC, NAT failure không cắt đường Worker → AI. Quyết định final ưu tiên cost-security fit cho capstone: giữ 1 zonal NAT + S3/DynamoDB Gateway Endpoints, không triển khai full interface VPCE trong infra baseline.*

## 2. Component table

Giả định tính chi phí final: region `us-west-2` làm baseline pricing, 730 giờ/tháng, 2 AZ, 3 service demo, prediction mỗi 5 phút, CloudWatch log retention 14 ngày, S3 raw failure buffer 7 ngày và evidence/baseline export 90 ngày. Đây là **chi phí platform baseline** cho demo scope, không phải chi phí phân bổ chính xác theo từng tenant. Giá chi tiết của network path được giải thích trong `vpce_vs_nat_cost_notes.md`; cost analysis tổng thể sẽ được chốt trong `05_cost_analysis.md`.

| Component | AWS Service | Reason | Cost note |
|---|---|---|---|
| Tầng compute | ECS Fargate | Chạy 2 task cho Telemetry API, 1 task cho Prediction Worker và 2 task cho AI Engine trong cùng ECS cluster. Fargate phù hợp vì không phải quản lý EC2, có task role riêng, và chạy được API, worker, AI serving theo cùng mô hình container/private subnet. | **$90.10/tháng** = 5 task × 730h × (0.5 vCPU × $0.04048 + 1GB × $0.004445). |
| Cổng API | Application Load Balancer + ACM | ALB nhận telemetry từ 3 service demo và tải synthetic từ k6, kết thúc HTTPS rồi chuyển request vào ECS service. ACM certificate không tính phí. | **$22.27/tháng** = ALB $16.43 + 1 LCU trung bình $5.84. |
| Kho metric TSDB | Amazon Timestream | Lưu metric theo tenant/service/time để worker query window 1-2 giờ. | **$5.00/tháng**: hạn mức dự kiến cho ~0.65M metric/tháng, memory store ngắn, magnetic store nhỏ, query luôn có time predicate. |
| Audit + service policy database | DynamoDB | Audit log là dữ liệu ghi nối tiếp, cần tra cứu nhanh theo tenant/service/time; service policy chứa metric allowlist, baseline, quota và fallback threshold. DynamoDB gọn hơn RDS cho key-value access pattern này. | **$0.10/tháng**: ~26k audit write/tháng + policy read nhỏ; read và storage rất nhỏ, nằm trong 25GB storage miễn phí. |
| Điều phối job | EventBridge Scheduler + SQS + DLQ | Scheduler tạo prediction job mỗi 5 phút; SQS tách worker khỏi độ trễ của AI; DLQ giữ job lỗi để debug. | **$0.05/tháng**: ~26k job/tháng, khoảng 3 SQS request/job; Scheduler gần như không đáng kể ở volume này. |
| Lưu trữ evidence + failure buffer | S3 | Lưu ALB access log, evidence/baseline export và raw telemetry buffer khi Timestream write fail; không dùng làm audit DB chính. | **$0.35/tháng**: giả định evidence/export giữ 90 ngày, raw failure buffer giữ 7 ngày, request nhỏ. |
| Quan sát hệ thống | CloudWatch + SNS | Ghi log task, custom metrics, alarm và dashboard; SNS gửi alert high-risk. | **$8.00/tháng**: 1 dashboard ~$3, 10-12 alarm ~$1-2, log ingest/storage khoảng ~$3; SNS email dưới 1k notification miễn phí. |
| Bảo mật / cấu hình | Secrets Manager + KMS | Lưu internal endpoint/config của AI Engine, model config/secret nếu có, mã hóa DynamoDB/SQS/Logs bằng KMS, không hardcode credential. | **$3.40/tháng**: 3 secret × $0.40 + 2 KMS key × $1 + request nhỏ. |
| Kết nối private subnet | NAT Gateway + S3/DynamoDB Gateway Endpoints | Quyết định final: 1 zonal NAT Gateway đặt ở public subnet và dùng chung bởi private subnets ở 2 AZ cho outbound AWS API traffic không đi qua Gateway Endpoint; S3/DynamoDB dùng Gateway Endpoint miễn phí hourly. Full interface VPCE no-NAT không được chọn vì fixed cost cao hơn rõ rệt ở traffic ~12GB/tháng. | **$33.39/tháng** = 1 NAT × 730h × $0.045/h + ~12GB × $0.045/GB; S3/DynamoDB Gateway Endpoint không có hourly/data processing charge. |
| Container registry | Amazon ECR | Lưu private image cho Telemetry API, Prediction Worker và AI Engine; ECS execution role pull image khi deploy/replace task qua NAT cho ECR API/DKR và qua S3 Gateway Endpoint cho image layer path. | **~$0.10-$1/tháng** cho image demo nhỏ; đã nằm trong buffer vận hành 20%. |
| Bảo vệ public ingest endpoint | ALB access log + app token bucket + source allowlist cho test traffic | Public ALB chỉ expose telemetry ingest path. Rate limiting ở application layer và giới hạn nguồn synthetic/client demo là baseline final; AWS WAF không nằm trong infra baseline để giữ tổng cost dưới $200. | **$0 AWS fixed cost thêm** ngoài ALB/CloudWatch/S3 log đã tính. |
| **Tổng baseline** |  | Network path dùng 1 zonal NAT + S3/DynamoDB Gateway Endpoints. | **~$162.66/tháng**. Thêm 20% buffer vận hành là **~$195.19/tháng**, thấp hơn budget **$200/tháng**. |

Cost guard:

- AWS Budget alarm tại 50%, 80%, 100% của **$200/tháng**.
- CloudWatch log retention cố định 14 ngày; S3 raw failure buffer 7 ngày, evidence/baseline export 90 ngày theo lifecycle policy.
- Synthetic load chỉ bật trong test window đã lên lịch.
- Timestream query bắt buộc có `tenant_id`, `service_id` và time predicate.
- Prediction cadence cố định 5 phút cho baseline; không dùng cadence 1 phút trong infra final.

## 3. Differentiation angle deep-dive

### 3.1 Why this angle?

Angle của nhóm là **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**. Điểm khác biệt không nằm ở việc dựng thêm dashboard, mà ở việc biến telemetry thành quyết định vận hành có thể kiểm chứng và audit được.

Client đã có Grafana, CloudWatch và Datadog trial. Vấn đề là dashboard không tự đưa ra cảnh báo sớm, còn threshold tĩnh thì dễ rơi vào hai cực: quá nhạy gây alert fatigue, hoặc quá trễ nên chỉ báo khi user đã bị ảnh hưởng. Vì vậy platform tập trung vào một luồng rõ ràng:

1. nhận metric từ 3 service demo;
2. lưu time-series metric vào Timestream;
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
| Budget fit | **~$162.66/tháng** baseline; **~$195.19/tháng** nếu thêm 20% buffer, dùng khoảng **97.6%** budget $200 | Dashboard-only có thể chỉ **$60-90/tháng**, nhưng không cover đủ prediction workflow, audit-per-call, fallback, evidence-link requirement và AI serving nội bộ |
| Cost / service | **~$54.22/service/tháng** baseline cho 3 service; **~$65.06/service/tháng** nếu tính 20% buffer | EKS/self-hosted TSDB hoặc observability stack riêng dễ tăng compute + ops overhead, khó giữ dưới $200 nếu vẫn cần queue, audit, alert, fallback path và AI serving |
| Cost / prediction cycle | 3 services × mỗi 5 phút ≈ **25,920 prediction cycles/tháng**; baseline ≈ **$0.0063/cycle**, with buffer ≈ **$0.0075/cycle** | Dashboard-only không có prediction cycle/audit decision tương đương; static alarm rẻ hơn nhưng không tạo capacity recommendation có confidence/evidence |
| Requirement coverage | Cover trực tiếp: **≥15 phút lead-time target**, per-service baseline, audit log mỗi prediction, static fallback, evidence link, encrypted stores | Dashboard-only fail pain point “không có người nhìn 24/7”; static threshold dễ alert fatigue hoặc miss slow drift; lakehouse/batch rẻ cho storage nhưng không hợp 5-min operational loop |
| Early-warning cadence | **5 phút** là balanced point: đủ nhanh để còn buffer cho yêu cầu cảnh báo trước ≥15 phút, nhưng chưa tăng query/job/audit volume quá mức | 1 phút nhanh hơn nhưng tăng noise/cost; 10 phút rẻ hơn nhưng giảm buffer cho yêu cầu cảnh báo sớm |
| Công vận hành | **2-3 giờ/tuần** nhờ dùng managed services: ECS Fargate, SQS, Timestream, DynamoDB | EKS hoặc self-hosted TSDB có thể **6-10 giờ/tuần** cho node, storage, upgrade, retention và incident handling |
| Thời gian onboard service | **15-30 phút/service**: khai báo metric, baseline, fallback threshold, smoke test | Làm dashboard/alarm thủ công thường **30-60 phút/service** và dễ thiếu audit consistency |

Điểm cost của thiết kế này không phải là rẻ nhất tuyệt đối. Rẻ nhất tuyệt đối sẽ là dashboard-only hoặc vài CloudWatch alarm tĩnh, nhưng hai hướng đó không giải quyết đúng pain point client đã nêu: không có người nhìn dashboard 24/7 và threshold tĩnh dễ quá nhạy hoặc quá trễ. Vì vậy tiêu chí tối ưu là **cost-to-requirement coverage**: với khoảng **$195.19/tháng** sau buffer, platform vẫn thấp hơn budget **$200/tháng** nhưng có đủ prediction cadence, audit trail, fallback path, evidence link, per-service baseline cho 3 service demo và AI serving nội bộ trong ECS cluster.

Balanced mode được chọn vì hợp với budget và yêu cầu lead time. Cadence 1 phút phát hiện nhanh hơn nhưng làm tăng Timestream query, SQS job, audit write và alert noise. Cadence 10 phút rẻ hơn nhưng không còn nhiều buffer cho yêu cầu cảnh báo trước tối thiểu 15 phút.

### 3.3 Weakness chấp nhận

- **Phức tạp hơn dashboard-only**: cần scheduler, queue, worker, TSDB, audit DB và alert path. Nhóm chấp nhận điểm này vì fallback và audit log là hard requirement.
- **CDO platform phải host thêm AI serving capacity**: so với thiết kế cũ gọi endpoint ngoài, ECS cluster cần thêm AI Engine task, health check, logs, scaling rule và SG rule nội bộ. Đổi lại, đường gọi prediction private hơn, ít phụ thuộc internet/NAT hơn và match deployment contract mới.
- **Phụ thuộc AI response quality**: AI response bắt buộc được schema-validate trước khi tạo warning. Response thiếu `root_cause` hoặc `recommendation` bị xem là invalid schema và kích hoạt static threshold fallback; audit ghi `fallback_reason = ai_invalid_response`.
- **Static fallback có false positive**: fallback chỉ dùng khi AI unavailable hoặc response invalid. Audit record luôn ghi `prediction_source = static_threshold_fallback` để SRE biết đây không phải prediction từ model.
- **Chi phí được kiểm soát bằng guardrail cố định**: CloudWatch log retention giữ 14 ngày, S3 lifecycle tách raw buffer 7 ngày khỏi evidence/baseline 90 ngày, và mọi query Timestream bắt buộc filter theo `tenant_id`, `service_id` và time window để giữ platform dưới budget $200/tháng.

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
- Worker gọi AI qua **internal target group trên ALB hiện có**; ALB dùng path-based routing: `/v1/ingest` → Telemetry API target group, `/v1/predict` → AI Engine target group. Endpoint nội bộ chốt: `http://<alb-internal-dns>/v1/predict`.
- Auth giữa Worker và AI dùng private service auth bằng service-to-service token lưu trong Secrets Manager; network layer: Worker SG gọi ALB SG; ALB SG chỉ forward `/v1/predict` đến AI Engine SG; không mở Worker SG → AI Engine SG trực tiếp.
- Request phải mang tenant context đã verify, không tự tin vào tenant header từ client.
- **SLA latency AI contract: P99 < 500ms.** Worker alarm khi AI p99 > 500ms (xem §6.1). CDO worker timeout hard limit 2 giây, sau đó fallback.
- Retry: 1-2 lần với backoff ngắn.
- Nếu AI timeout, 5xx, 429 vượt retry, hoặc response sai schema, worker dùng static threshold fallback.
- Worker inject `context.deployment_version` từ **ECR image digest (SHA256)** của ECS task đang chạy, đọc qua ECS task metadata endpoint (`169.254.170.2/v4/metadata`) lúc startup, cached cho vòng đời task.
- CDO lưu audit record dùng **đúng tên field của AI response** (không mapping): `anomaly`, `severity`, `reasoning`, `recommendation.action_verb`, `recommendation.target`, `recommendation.from_to`, `recommendation.confidence`, `audit_id`. Xem schema tại §4.1.

### 4.3 Isolation pattern

- **Data isolation**: dùng pooled model. Timestream lưu `tenant_id`, `service_id`, `env`, `region` dưới dạng dimensions. DynamoDB dùng partition key có tenant/service để tránh query lẫn tenant.
- **Compute isolation**: basic/pro/enterprise trong capstone dùng chung ECS services với tenant-aware quota, policy và audit boundary để giữ cost dưới $200/tháng; không tách worker service riêng theo tenant trong baseline.
- **Lý do chọn pooled model**: đủ để chứng minh multi-tenant trong capstone mà không nhân đôi ALB, ECS cluster hay database cho từng tenant.

Tenant-aware rules:

- Mọi runtime query bắt buộc include `tenant_id`.
- Service phải thuộc tenant trước khi ghi metric hoặc query audit.
- Tenant A không đọc được audit/evidence của tenant B.
- Không đưa PII vào metric, audit key hoặc Timestream dimensions.

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
- TTL audit: 90 ngày cho baseline final.
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
ADR: ghi rõ trigger logic; infra lưu baseline_version trong service policy và audit record
```

### 4.6 Timestream data model

Phần này bổ sung cách pooled tenant model được biểu diễn trong TSDB hot path: tenant/service là dimensions bắt buộc, còn high-cardinality IDs không được dùng làm dimensions.

Dimensions ổn định:

```text
tenant_id
service_id
env
region
service_tier
```

Không dùng high-cardinality dimensions:

```text
request_id
trace_id
prediction_id
```

Multi-measure record theo `tenant_id + service_id + timestamp`. Measure fields align với telemetry contract signal names:

```text
api_latency_ms
cpu_usage_percent
memory_usage_percent
error_rate
db_connection_pool_pct
queue_depth
oldest_message_age_seconds
cache_hit_rate_pct
active_connections
```

Retention:

```text
Memory store: 24h cho recent prediction window
Magnetic store: 30 ngày cho evidence/demo
S3 evidence + aggregated baseline export: 90 ngày theo lifecycle
S3 raw telemetry failure buffer: 7 ngày hoặc xóa ngay sau replay thành công
```

Query pattern bắt buộc:

```sql
WHERE tenant_id = ?
  AND service_id = ?
  AND time BETWEEN ago(2h) AND now()
```

Không query toàn tenant/all services trong runtime path. Dashboard/evidence query dùng window nhỏ và filter service cụ thể.

### 4.7 Tenant onboarding flow

```text
1. POST /platform/v1/tenants (tenant_name, contact, tier)
2. Verify credential mapping với tenant_id
3. Tạo service policy cho payment-gateway, ledger-service, kyc-worker: enabled metrics, quota, baseline version, fallback rules
4. Cấu hình baseline và static fallback threshold theo từng service
5. Đăng ký metric labels/dimensions trong Timestream
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
| Lookback window | tối đa 2h | tối đa 2h | Giữ Timestream query cost ổn định |

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
- Target group type `ip`, health check `/health`, grace period 60-90 giây.
- Deployment circuit breaker bật rollback, `minimumHealthyPercent=100`, `maximumPercent=200`.
- Tách `executionRoleArn` để pull image/logs/secrets và `taskRoleArn` để ứng dụng gọi Timestream, DynamoDB, SQS, SNS.
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
| Metrics store | S3 metric lake | Rẻ cho dữ liệu lịch sử. | Không tối ưu query window 1-2 giờ mỗi 5 phút. | Không chọn cho hot path. |
| Metrics store | Amazon Timestream | Phù hợp time-series, có memory/magnetic retention, query theo service/time tốt. | Query sai pattern có thể tăng cost. | ✅ **Chọn** làm TSDB cho prediction và evidence. |
| Điều phối prediction | Scheduler gọi worker trực tiếp | Ít thành phần. | AI timeout có thể làm mất job hoặc block luồng xử lý. | Không chọn. |
| Điều phối prediction | EventBridge Scheduler → SQS → Worker | Có retry, DLQ, scale worker theo backlog, dễ demo failure path. | Thêm queue cần monitor. | ✅ **Chọn** cho control plane. |

## 6. Scaling strategy

| Thành phần | Sizing mặc định | Khi nào tăng | Giới hạn baseline |
|---|---|---|---|
| Telemetry API | 2 task × 0.5 vCPU / 1GB | CPU >70%, memory >75%, ALB p99 vượt target | Max 5 task |
| Prediction Worker | 1 task × 0.5 vCPU / 1GB | Queue age >2 phút, visible messages >20 trong 5 phút, backlog-per-task cao, worker timeout | Max 5 task |
| AI Engine | 2 task × 0.5 vCPU / 1GB | AI p95 >350ms trong 5 phút (early warning), AI p99 >500ms (SLO breach), 5xx tăng, CPU >70%, hoặc request count/task vượt baseline | Max 5 task |
| Worker nâng cấp | 1 vCPU / 2GB | Timestream query + AI call thường xuyên vượt timeout hoặc memory >75% | Ưu tiên nâng worker trước API vì bottleneck prediction nằm ở query + AI call path |

Scaling triggers:

| Component | Trigger | Action | Bounds baseline |
|---|---|---|---|
| Telemetry API | CPU >70%, memory >75%, hoặc ALB `RequestCountPerTarget > 200 req/min` trong 5 phút | Thêm 1 task | Min 2, max 5 |
| Prediction Worker - backlog | `ApproximateNumberOfMessagesVisible > 20` trong 5 phút | Thêm 1 worker task | Min 1, max 5 |
| Prediction Worker - lag | `ApproximateAgeOfOldestMessage > 2 phút` | Scale worker ngay và gửi SNS alert | Max 5 |
| Prediction Worker - scale-in | Queue trống và CPU <30% trong 10 phút | Giảm 1 worker task | Không dưới 1 task |
| AI Engine - early warning | p95 latency >350ms trong 5 phút | Gửi SNS, kiểm tra image/runtime, xem xét provisioned concurrency hoặc scale nếu p99 đang tăng | Min 2, max 5 |
| AI Engine - SLO breach | p99 latency >500ms hoặc 5xx >1% trong 5 phút | Thêm 1 AI task hoặc rollback AI version; gửi SNS nếu fallback rate tăng | Min 2, max 5 |

Ngoài autoscaling, theo dõi DLQ depth > 0, DynamoDB throttles, Timestream rejected records/query error và AI fallback rate tăng bất thường.

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
2. Query Timestream
3. Call AI hoặc static fallback
4. Conditional write audit vào DynamoDB
5. Publish alert nếu risk high
6. Delete SQS message cuối cùng
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
| Data stores | Timestream rejected/query errors, DynamoDB throttles/system errors |
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
| Timestream rejected records | >0 | SNS |
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
| Worker SG | Không mở inbound | HTTPS/443 tới SQS/Timestream/SNS/Secrets Manager/CloudWatch/ECR control plane qua 1 zonal NAT; DynamoDB audit/policy qua DynamoDB Gateway Endpoint; app port tới ALB SG (predict path nội bộ) |
| AI Engine SG | Chỉ từ ALB SG vào app port; health check từ ALB target group | HTTPS/443 tới CloudWatch/Secrets Manager/ECR control plane qua 1 zonal NAT; không mở inbound từ Worker SG trực tiếp hoặc internet |

IAM role:

| Role | Quyền chính |
|---|---|
| ECS execution role | Pull image từ ECR, ghi CloudWatch Logs, đọc secret cần inject lúc start |
| Telemetry API task role | Timestream write, CloudWatch metric/log, `s3:PutObject` chỉ vào failure-buffer prefix; không có quyền DynamoDB audit write vì API không tạo prediction |
| Worker task role | SQS receive/delete, Timestream query, DynamoDB `PutItem/Query/GetItem` audit + service policy, SNS publish, Secrets Manager read |
| AI Engine task role | Đọc model/config secret cần thiết, ghi CloudWatch Logs/custom metrics; không có quyền đọc audit table hoặc SQS prediction queue |
| EventBridge Scheduler execution role | Chỉ `sqs:SendMessage` vào prediction queue ARN; không có quyền truy cập VPC resource |
| Buffer replay role (break-glass) | Đọc failure-buffer prefix, ghi lại Timestream; không có quyền đọc audit table hoặc secret không liên quan |

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
| Timestream write/query failure | Rejected records, query error, worker log error | API retry bounded; nếu vẫn fail thì ghi raw payload + idempotency key vào S3 failure buffer và trả `202 Accepted`; nếu S3 cũng fail thì trả 5xx/429 để producer retry. Replayer chạy theo runbook để backfill TSDB; worker retry query với backoff. | 5-15min | Gần 0 nếu S3 buffer hoặc producer retry thành công |
| DynamoDB audit throttling/unavailable | DynamoDB throttle metric, worker `PutItem` error | SDK retry/backoff; chỉ delete SQS message sau khi audit write thành công | < 5min | Gần 0 nếu message vẫn còn trong SQS |
| Secrets/KMS access denied | Task startup/runtime decrypt error | Rollback task definition/role/key policy | < 15min | Không mất data, nhưng có thể delay prediction |
| SNS/alert channel failure | SNS delivery failure hoặc không nhận confirmation khi test | Audit vẫn là source of truth; sửa subscription rồi replay alert từ audit | < 15min | 0 cho audit, alert có thể delay |
| Cost guard triggered | Budget alarm hoặc custom cost metric | Giữ cadence 5 phút, giảm synthetic load/log verbosity, không tắt audit/fallback | Same day | 0 cho core audit |

Telemetry API trả `200/201` khi Timestream write accepted. Nếu Timestream vẫn fail sau bounded retry nhưng raw payload đã được lưu bền vững vào S3 failure buffer, API trả `202 Accepted` kèm request/event id để xác nhận sẽ replay; chỉ trả `5xx/429` khi cả Timestream và S3 buffer đều thất bại. Failure buffer có alarm khi object age >5 phút và replay target trong 5-15 phút. Nếu prediction worker chạy trước khi telemetry buffered được replay, audit/evidence phải gắn cờ `evidence_status = partial_window` để SRE biết decision dựa trên window chưa đầy đủ. Prediction worker chỉ delete SQS message sau khi audit write thành công.

## Related documents

- [`03_security_design.md`](03_security_design.md) - Network Security §4 + IAM §5 + Data Security §6 expand on infra concerns
- [`04_deployment_design.md`](04_deployment_design.md) - IaC + CI/CD + GitOps cho infra này
- [`05_cost_analysis.md`](05_cost_analysis.md) - Platform baseline và mô hình phân bổ chi phí per-tenant dựa trên infra này
- [`08_adrs.md`](08_adrs.md) - Infra architecture decisions
