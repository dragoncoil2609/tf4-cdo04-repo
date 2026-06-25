# Cost Analysis - Task Force 4 · CDO 04

<!-- Doc owner: Tạ Hoàng Huy (Huy)
     Status: Refined (W11 T6 Pack #1) - v1.5
     Word target: 1000-1500 từ -->

> **Scope note**: Platform của nhóm không dùng LLM/Bedrock. AI Engine (Nhóm AI) chạy statistical ML.
> Cost "AI inference" trong doc này = data transfer CDO→AI endpoint + Fargate compute của Prediction Worker,
> không phải per-token LLM cost. Điều này là điểm khác biệt cốt lõi so với template mặc định.

---

## 1. Cost model per monitored service unit (forecast)

> **Định nghĩa "monitored service unit" trong TF4**: một service được monitor (ví dụ `payment-gateway`) với per-service
> baseline riêng biệt. Capstone demo với 3 monitored service units. Production scale = số service tier-1 được onboard.

### 1.1 Shared fixed cost (platform-level, amortized)

Chi phí này tồn tại độc lập với số lượng monitored service unit và được chia đều cho toàn bộ hệ thống:

| Component | AWS Service | Config | $/month (fixed) |
|---|---|---|---|
| Telemetry API | ECS Fargate | 2 tasks · 0.5 vCPU · 1GB RAM · always-on | ~$36.04 |
| AI Engine | ECS Fargate | 2 tasks · 0.5 vCPU · 1GB RAM · always-on | ~$36.04 |
| NAT Gateway | VPC | 1 zonal NAT · us-west-2 (Oregon) | ~$32.85 |
| Application Load Balancer | ALB | 1 ALB · us-west-2 (Oregon) · always-on | ~$16.43 |
| CloudWatch Dashboard | CloudWatch | 1 dashboard dùng chung | ~$3.00 |
| Secrets Manager & KMS | Secrets Manager/KMS | 3 secrets · 2 KMS keys | ~$3.40 |
| EventBridge Scheduler | Scheduler | Base scheduler setup | ~$0.01 |
| **Total fixed** | | | **~$127.77/month** |

> **Lưu ý về Compute (Telemetry & AI Engine)**: Chi phí $36.04/tháng cho mỗi component được tính toán dựa trên đơn giá Fargate tại region `us-west-2` (CPU: $0.04048/vCPU-hour, Memory: $0.004445/GB-hour) cho 2 tasks chạy always-on 24/7 để đảm bảo độ sẵn sàng cao.
>
> **Lưu ý NAT Gateway**: $32.85/tháng (tính theo đơn giá $0.045/giờ tại Oregon `us-west-2`) là một trong các chi phí cố định lớn nhất. MVP sử dụng S3/DynamoDB Gateway Endpoints để giảm chi phí xử lý dữ liệu (data processing) qua NAT Gateway.
>
> **Lưu ý Application Load Balancer**: Chi phí $16.43/tháng là chi phí cố định theo giờ chạy của ALB ($0.0225/giờ). Phí LCU biến đổi được tách riêng trong phần biến phí.

### 1.2 Variable cost per monitored service unit (per service monitored)

| Component | AWS Service | Unit cost | Avg usage/month | $/monitored-service-unit/month |
|---|---|---|---|---|
| Fargate compute (Prediction Worker) | ECS Fargate | 1 task always-on shared | 0.5 vCPU · 1GB RAM (Phân bổ cho 3 service) | ~$6.01 |
| ALB LCU charge | ALB | $0.008 / LCU-hour | ~1 LCU trung bình (Phân bổ cho 3 service) | ~$1.95 |
| Metric storage & query | Amazon Timestream | $0.62/M writes + $0.01/GB scan | Phân bổ từ baseline $5.00/tháng cho 3 service | ~$1.67 |
| CloudWatch logs & metrics | CloudWatch | $0.50/GB logs + $0.30/metric | Phân bổ từ baseline $5.00/tháng (logs, alarms, metrics) | ~$1.67 |
| S3 storage & buffer | S3 | $0.023/GB-month | Phân bổ từ baseline $0.35/tháng cho 3 service | ~$0.12 |
| Audit database | DynamoDB | $1.25/million writes | Phân bổ từ baseline $0.10/tháng cho 3 service | ~$0.03 |
| SQS & Scheduler | SQS | $0.40/million requests | Phân bổ từ baseline $0.04/tháng cho 3 service | ~$0.01 |
| NAT data processing | NAT Gateway | $0.045 / GB processed | ~4 GB (12 GB total / 3 services) | ~$0.18 |
| **Total variable / monitored-service-unit / month** | | | | **~$11.63** |

### 1.3 Total per-monitored-service-unit cost (platform amortized)

| Monitored service unit count | Fixed cost/month | Variable/month | **Total/month (Baseline)** | **Total with 20% Buffer** | **Per-service-unit (No Buffer)** | **Per-service-unit (With Buffer)** |
|---|---|---|---|---|---|---|
| 3 (capstone demo) | $127.77 | $34.89 | **$162.66** | **$195.19** | **$54.22** | **$65.06** |
| 10 | $127.77 | $116.30 | **$244.07** | **$292.88** | **$24.41** | **$29.29** |
| 50 | $127.77 | $581.50 | **$709.27** | **$851.12** | **$14.19** | **$17.02** |

---

## 2. Cost at scale

### 2.1 Assumptions for scale estimate (Các giả định tính toán quy mô)
Để đưa ra các dự báo chi phí dưới đây, nhóm CDO tuân thủ các giả định thực tế sau:
- **Số lượng metrics**: Giới hạn ở mức 6 metrics/service.
- **Cadence**: Tần suất lấy mẫu và gọi dự đoán là 5 phút/lần.
- **Dung lượng log**: Thấp (low log volume, dưới 0.5 GB/service/tháng).
- **Phạm vi giao diện**: Không triển khai toàn bộ các endpoint giao diện phức tạp (no full interface endpoints), chỉ tập trung vào telemetry ingestion API và prediction worker.
- **Mô hình AI**: Không sử dụng mô hình LLM/Bedrock (chỉ chạy ML thống kê).

### 2.2 Dự báo chi phí theo quy mô

| Monitored service unit count | Monthly total (Baseline) | Monthly total (With 20% Buffer) | Avg per-service-unit (With Buffer) | Ghi chú |
|---|---|---|---|---|
| 3 | ~$163 | ~$195 | ~$65.06 | Môi trường Capstone Demo — fixed cost chưa được phân bổ tối ưu |
| 10 | ~$244 | ~$293 | ~$29.29 | Quy mô sản xuất nhỏ (Small Production) — bắt đầu vượt budget $200 |
| 50 | ~$709 | ~$851 | ~$17.02 | Quy mô mục tiêu (Production Target) |
| 100 | ~$1,291 | ~$1,549 | ~$15.49 | Quy mô lớn (Large Production) |

*Per-service-unit cost giảm dần khi quy mô tăng vì fixed cost ($127.77) được phân bổ đều cho nhiều service unit hơn. Từ 50 service units trở lên, variable cost bắt đầu chiếm ưu thế.*

---

## 3. Cost optimization applied

### 3.1 Đã áp dụng trong thiết kế hạ tầng

- [x] **Gateway Endpoints cho S3 & DynamoDB**: MVP sử dụng 1 NAT Gateway kết hợp với S3/DynamoDB Gateway Endpoints để chuyển hướng một phần lượng lưu lượng nội bộ trực tiếp trên hạ tầng AWS. Điều này giúp giảm thiểu chi phí NAT data processing.
- [x] **Event-driven Prediction Worker**: Dù được tính toán dưới dạng always-on Fargate task cho baseline an toàn trong thiết kế, worker được triển khai tối ưu hóa để tận dụng hàng đợi SQS, giúp dễ dàng điều phối và giảm tải tài nguyên trong các môi trường non-production.
- [x] **DynamoDB On-Demand Billing**: Không đặt trước dung lượng (provisioned capacity), chỉ trả phí dựa trên số lần ghi thực tế của Audit Log (cực kỳ rẻ cho tần suất 5 phút/lần).
- [x] **Timestream Magnetic Tiering**: Cấu hình Memory store ngắn hạn (24h) và tự động đẩy dữ liệu cũ sang Magnetic store giúp tối ưu chi phí lưu trữ chuỗi thời gian.
- [x] **CloudWatch Log Retention (14 ngày)**: Giới hạn thời gian lưu trữ log thay vì lưu vô hạn để tránh phình chi phí lưu trữ CloudWatch Logs.
- [x] **Tối ưu hóa số lượng Custom Metrics**: Hạn chế số lượng custom metric gửi lên CloudWatch ở mức tối thiểu cần thiết (~6 metrics/service) để tránh "bẫy chi phí" của CloudWatch ($0.30/metric/tháng).

### 3.2 Không áp dụng (và lý do)

- [ ] **Fargate Spot Instances**: Không áp dụng cho Telemetry API để đảm bảo độ sẵn sàng dịch vụ (SLO Availability $\ge$ 99.5%).
- [ ] **Reserved Capacity / Savings Plans**: Không áp dụng do thời gian thử nghiệm Capstone ngắn (2 tuần), không đủ điều kiện cam kết tối thiểu 1 năm của AWS.
- [ ] **Bedrock Prompt Caching**: Hệ thống chạy statistical ML cục bộ trên ECS Fargate của nhóm AI, không gọi API Generative AI (Bedrock) nên tính năng này không khả dụng.

---

## 4. NAT Gateway vs VPC Endpoint Cost-Benefit Analysis

Tài liệu này chốt lại lựa chọn giữa **NAT Gateway** và **VPC Endpoint** cho kiến trúc trong [`02_infra_design.md`](02_infra_design.md) sau khi AI Engine đã được host nội bộ trong cùng ECS Cluster/VPC.

Phạm vi tính toán đã chốt:

```text
Region: us-west-2 / US West (Oregon)
Topology: Multi-AZ, 2 private subnets/AZ cho ECS Fargate
Runtime: Telemetry API + Prediction Worker + AI Engine trong private subnets
AI endpoint: internal service discovery/private DNS, không đi qua NAT hoặc VPCE
Month: 730 hours
```

### 4.1 Nguồn kiểm chứng

Thông tin bên dưới được kiểm tra bằng AWS MCP, AWS Pricing API và tài liệu AWS chính thức.

#### NAT Gateway pricing tại `us-west-2`

AWS Pricing API trả về cho `AmazonEC2`, location `US West (Oregon)`, group `NGW:NatGateway`:

| Item | AWS Pricing API field | Giá |
|---|---|---:|
| NAT Gateway hourly | `USW2-NatGateway-Hours` | **$0.045 / NAT Gateway-hour** |
| NAT Gateway data processing | `USW2-NatGateway-Bytes` | **$0.045 / GB processed** |

Ghi chú:
* NAT Gateway tính phí theo giờ chạy của từng NAT Gateway.
* NAT Gateway tính thêm data processing theo GB.
* Nếu private subnet ở AZ khác route qua một NAT Gateway đặt ở một AZ duy nhất, có thể phát sinh thêm cross-AZ data transfer charge. Với traffic demo của CDO04, phần này rất nhỏ nhưng là điểm yếu HA/security của zonal NAT.

#### Interface VPC Endpoint / AWS PrivateLink pricing tại `us-west-2`

AWS Pricing API trả về cho `AmazonVPC`, location `US West (Oregon)`, group `VPCE:VpcEndpoint`:

| Item | AWS Pricing API field | Giá |
|---|---|---:|
| Interface VPCE hourly | `USW2-VpcEndpoint-Hours` | **$0.010 / endpoint-AZ-hour** |
| Interface VPCE data processing | `USW2-VpcEndpoint-Bytes` | **$0.010 / GB processed** cho first 1 PB/tháng |

Ghi chú:
* Interface endpoint được tính theo **mỗi endpoint trong mỗi AZ**.
* Multi-AZ 2 AZ nghĩa là 1 service endpoint = 2 endpoint-AZ-hour streams.
* VPCE data processing rẻ hơn NAT data processing, nhưng fixed hourly cost tăng nhanh nếu cần nhiều endpoint.

#### Gateway VPC Endpoint

AWS docs xác nhận Gateway Endpoint dùng cho:
```text
S3
DynamoDB
```
Cost model:
```text
S3 Gateway Endpoint      = $0/hour, $0/GB endpoint processing
DynamoDB Gateway Endpoint = $0/hour, $0/GB endpoint processing
```
Gateway Endpoint là lựa chọn mặc định cho CDO04 vì S3 failure buffer/evidence export và DynamoDB audit/policy không cần đi qua NAT.

#### Timestream endpoint correction

Giả định cũ “Timestream không có VPC endpoint” là **sai**.

AWS Timestream for LiveAnalytics hỗ trợ interface VPC endpoints, nhưng do kiến trúc cell-based nên cần **2 interface endpoints riêng**:
```text
com.amazonaws.<region>.timestream.ingest-<cell>
com.amazonaws.<region>.timestream.query-<cell>
```
Trong `us-west-2`, phải gọi `DescribeEndpoints` để xác định `<cell>` của account, ví dụ `cell1`, rồi tạo:
```text
com.amazonaws.us-west-2.timestream.ingest-cell1
com.amazonaws.us-west-2.timestream.query-cell1
```
Ý nghĩa với CDO04:
* Telemetry API ghi metric vào Timestream Write API → cần `timestream.ingest-<cell>` nếu no NAT.
* Prediction Worker query metric window 1-2h → cần `timestream.query-<cell>` nếu no NAT.

### 4.2 Endpoint set đầy đủ nếu bỏ NAT hoàn toàn

Nếu CDO04 chọn mô hình **no NAT**, toàn bộ AWS API traffic từ private ECS tasks phải đi qua Gateway Endpoint hoặc Interface Endpoint.

#### Gateway endpoints bắt buộc, không tính hourly

| Endpoint | Type | Dùng bởi | Lý do |
|---|---|---|---|
| `com.amazonaws.us-west-2.s3` | Gateway | ECS/ECR image layer pull, S3 failure buffer, ALB logs, evidence export | S3 gateway endpoint free, giảm NAT data processing |
| `com.amazonaws.us-west-2.dynamodb` | Gateway | Prediction Worker | Audit log + service policy DB |

#### Interface endpoints bắt buộc cho no-NAT runtime

Với workload hiện tại, cần **10 interface endpoints** trong 2 AZ:

| # | Endpoint service name | Dùng bởi | Vì sao cần nếu không có NAT |
|---:|---|---|---|
| 1 | `com.amazonaws.us-west-2.ecr.api` | ECS execution role | Gọi ECR API để lấy image metadata/auth flow |
| 2 | `com.amazonaws.us-west-2.ecr.dkr` | ECS execution role | Docker Registry API khi pull image |
| 3 | `com.amazonaws.us-west-2.logs` | ECS execution role + app | Gửi container logs vào CloudWatch Logs |
| 4 | `com.amazonaws.us-west-2.monitoring` | Telemetry API / Worker / AI | Gửi custom metrics, health/fallback/AI latency metrics vào CloudWatch Metrics |
| 5 | `com.amazonaws.us-west-2.secretsmanager` | ECS tasks | Đọc runtime secrets/config của platform và AI Engine |
| 6 | `com.amazonaws.us-west-2.kms` | ECS tasks / AWS SDK | KMS decrypt cho secrets/config hoặc app-level encrypted payload nếu gọi trực tiếp |
| 7 | `com.amazonaws.us-west-2.sqs` | Prediction Worker | Receive/delete prediction jobs và DLQ interactions |
| 8 | `com.amazonaws.us-west-2.sns` | Prediction Worker | Publish high-risk alerts |
| 9 | `com.amazonaws.us-west-2.timestream.ingest-<cell>` | Telemetry API / replay role | Timestream Write API |
| 10 | `com.amazonaws.us-west-2.timestream.query-<cell>` | Prediction Worker | Timestream Query API |

Không tính trong baseline:

| Endpoint | Lý do không đưa vào cost baseline |
|---|---|
| `events` / EventBridge | EventBridge Scheduler là regional managed service gửi message vào SQS, không chạy trong VPC. ECS tasks không gọi EventBridge API trong runtime path. |
| `ecs`, `ecs-agent`, `ecs-telemetry` | CDO04 không chạy ECS control-plane calls từ app container. Fargate orchestration do AWS quản lý; chỉ cần ECR/logs/secrets cho task runtime. |
| `sts` | AI endpoint hiện internal; không còn STS assume-role cross-service trong baseline. Nếu sau này contract yêu cầu STS, thêm 1 interface endpoint. |
| `ssm`, `ssmmessages`, `ec2messages` | Chỉ cần nếu dùng SSM Parameter Store hoặc ECS Exec. Baseline dùng Secrets Manager và không yêu cầu ECS Exec. |
| `xray` | Chưa nằm trong observability baseline. |

### 4.3 Traffic model gần đúng từ infra design

Dựa trên `02_infra_design.md`, traffic đi qua NAT hoặc interface VPCE chỉ là traffic từ **private ECS tasks** tới AWS service APIs. AI call nội bộ `Worker → AI Engine` đi trong VPC, không đi NAT/VPCE. Ingest từ client vào public ALB cũng không tính vào NAT/VPCE.

Giả định workload đã chốt:
* 3 demo services
* Telemetry frequency: 1 phút
* Prediction cadence: 5 phút
* Prediction cycles: 3 services × 12 cycles/hour × 24 × 30 = 25,920 jobs/tháng
* Metric volume: khoảng 0.65M metric points/tháng theo infra design
* CloudWatch log cost estimate hiện tại: khoảng $3 log ingest/storage trong component table

Ước tính traffic AWS API hàng tháng:

| Traffic source | Đi đâu | Có đi NAT trong giải pháp hiện tại? | Có đi VPCE trong no-NAT? | Ước tính GB/tháng | Cách estimate |
|---|---|---:|---:|---:|---|
| Timestream writes | Timestream Write API | Có | `timestream.ingest-<cell>` | ~0.8 GB | 0.65M points × khoảng 1 KB/request payload + overhead |
| Timestream queries | Timestream Query API | Có | `timestream.query-<cell>` | ~2.2 GB | 25,920 jobs × 1-2h window, 3-5 metrics/service, response aggregate/raw window nhỏ |
| CloudWatch Logs | CloudWatch Logs | Có | `logs` | ~6.0 GB | Component table đang estimate khoảng $3 log ingest/storage; dùng ~6GB log ingest làm conservative runtime traffic |
| CloudWatch custom metrics | CloudWatch Metrics | Có | `monitoring` | ~0.2 GB | CPU/memory/fallback/AI latency/custom metric calls nhỏ |
| SQS | SQS API | Có | `sqs` | ~0.2 GB | ~26k jobs, receive/delete/change visibility, message body nhỏ |
| SNS | SNS API | Có | `sns` | ~0.05 GB | Chỉ high-risk alert, volume thấp |
| Secrets Manager | Secrets Manager API | Có | `secretsmanager` | ~0.05 GB | Task startup/refresh secrets, request nhỏ |
| KMS | KMS API | Có | `kms` | ~0.05 GB | Decrypt calls nhỏ; nhiều encryption at rest do managed services xử lý ngoài VPC path |
| ECR API/DKR control | ECR API + DKR | Có | `ecr.api` + `ecr.dkr` | ~0.3 GB | Metadata/auth/registry calls cho vài image deploy/replacement |
| ECR image layers + S3 buffer/evidence | S3 | Không, qua S3 Gateway Endpoint | S3 Gateway Endpoint | ~2-5 GB nhưng $0 VPCE/NAT processing | Image layers và S3 evidence/failure buffer route qua S3 gateway endpoint |
| Audit/policy | DynamoDB | Không, qua DynamoDB Gateway Endpoint | DynamoDB Gateway Endpoint | <0.1 GB nhưng $0 VPCE/NAT processing | 26k audit writes + policy reads nhỏ |

Traffic tính phí qua NAT/interface VPCE:
```text
Timestream        ~3.0 GB/month
CloudWatch        ~6.2 GB/month
SQS/SNS           ~0.25 GB/month
Secrets/KMS       ~0.10 GB/month
ECR control       ~0.30 GB/month
--------------------------------
Estimated total   ~9.85 GB/month
Rounded model     10 GB/month
Conservative      12 GB/month
```
Tài liệu này dùng **12 GB/tháng** làm traffic model để không under-estimate.

### 4.4 Công thức tính cho 2 AZ tại `us-west-2`

Ký hiệu:
```text
G = GB/tháng đi qua NAT hoặc Interface VPCE
N = số interface endpoints
```

#### Current infra design: 1 zonal NAT + S3/DynamoDB Gateway Endpoints
```text
Cost = 1 × 730 × $0.045 + G × $0.045
     = $32.85 + G × $0.045
```
* **Ghi chú**:
  * Đây là giải pháp hiện tại trong `02_infra_design.md`.
  * S3 và DynamoDB đã đi Gateway Endpoint nên không cộng vào NAT data processing.
  * Không HA cho egress. Nếu AZ chứa NAT lỗi, private tasks có thể mất đường gọi public AWS APIs.
  * Có thể có cross-AZ data transfer nhỏ nếu task ở AZ khác route qua NAT duy nhất.

#### HA NAT: 2 NAT Gateways, mỗi AZ một NAT + S3/DynamoDB Gateway Endpoints
```text
Cost = 2 × 730 × $0.045 + G × $0.045
     = $65.70 + G × $0.045
```
* **Ghi chú**:
  * HA hơn zonal NAT.
  * Route table mỗi private subnet đi NAT cùng AZ để tránh cross-AZ NAT path.
  * Vẫn có outbound internet path cho AWS APIs chưa private hóa.

#### Full VPCE no-NAT: 10 interface endpoints × 2 AZ + S3/DynamoDB Gateway Endpoints
```text
Cost = 10 endpoints × 2 AZ × 730 × $0.010 + G × $0.010
     = $146.00 + G × $0.010
```
* **Ghi chú**:
  * Không cần NAT cho AWS service runtime traffic.
  * Security posture tốt nhất: private connectivity, endpoint policy, SG trên endpoint ENI, không mở outbound internet cho AWS APIs.
  * Fixed hourly cost cao vì cần 10 interface endpoints trong 2 AZ.

### 4.5 Cost comparison tại `us-west-2`

Pricing dùng trong bảng:
```text
NAT Gateway:       $0.045/hour + $0.045/GB
Interface VPCE:    $0.010/endpoint-AZ-hour + $0.010/GB
Gateway Endpoint:  $0/hour + $0 endpoint processing for S3/DynamoDB
```

| Mô hình | Công thức | 0 GB | 12 GB realistic | 100 GB | 500 GB | 3,000 GB |
|---|---:|---:|---:|---:|---:|---:|
| Current: 1 zonal NAT + S3/DDB Gateway EP | `$32.85 + G × $0.045` | **$32.85** | **$33.39** | **$37.35** | **$55.35** | **$167.85** |
| HA NAT: 2 NAT + S3/DDB Gateway EP | `$65.70 + G × $0.045` | **$65.70** | **$66.24** | **$70.20** | **$88.20** | **$200.70** |
| Full VPCE no-NAT: 10 interface EP × 2 AZ + S3/DDB Gateway EP | `$146.00 + G × $0.010` | **$146.00** | **$146.12** | **$147.00** | **$151.00** | **$176.00** |

#### Break-even

| So sánh | Break-even traffic |
|---|---:|
| Full VPCE no-NAT vs current 1 zonal NAT | `(146.00 - 32.85) / (0.045 - 0.010)` = **~3,233 GB/tháng** |
| Full VPCE no-NAT vs HA 2 NAT | `(146.00 - 65.70) / (0.045 - 0.010)` = **~2,294 GB/tháng** |

Với traffic realistic **~12 GB/tháng**, full VPCE đắt hơn:
```text
Full VPCE vs current zonal NAT: $146.12 - $33.39 = +$112.73/tháng
Full VPCE vs HA NAT:            $146.12 - $66.24 = +$79.88/tháng
```

### 4.6 Security comparison

| Mô hình | Cost | Security posture | HA egress | Nhận xét |
|---|---|---|---|---|
| Current 1 zonal NAT + S3/DDB Gateway EP | Thấp nhất | Trung bình-khá | Không HA cho egress | Rẻ nhất cho demo. S3/DDB private, AI internal, nhưng các AWS APIs còn lại đi outbound qua NAT. |
| HA 2 NAT + S3/DDB Gateway EP | Trung bình | Trung bình-khá | Có HA theo AZ | Tốt hơn zonal NAT về HA nhưng vẫn là outbound NAT path. |
| Full VPCE no-NAT | Cao nhất ở traffic thấp | Tốt nhất | Có HA nếu endpoint đặt ở 2 AZ | Private-only cho AWS APIs, endpoint policy/SG tốt hơn, nhưng fixed cost cao với 10 endpoints. |

Điểm security đã được cải thiện so với bản cũ vì AI endpoint hiện là internal endpoint trong VPC. Do đó NAT/VPCE decision chủ yếu ảnh hưởng đến AWS service APIs như Timestream, CloudWatch, SQS, SNS, ECR, Secrets Manager và KMS; không còn ảnh hưởng đến đường gọi AI prediction.

### 4.7 Decision cho CDO04

#### Kết luận cost

Với traffic platform gần đúng **~12 GB/tháng**, giải pháp hiện tại **1 zonal NAT Gateway + S3/DynamoDB Gateway Endpoints** là rẻ nhất:
* Current zonal NAT: ~ $33.39/month
* HA 2 NAT:          ~ $66.24/month
* Full VPCE no-NAT:  ~ $146.12/month

Full VPCE chỉ bắt đầu có lợi về cost khi traffic AWS API qua private egress vượt khoảng:
* ~3.2 TB/month so với current zonal NAT
* ~2.3 TB/month so với HA 2 NAT

CDO04 hiện chỉ khoảng **12 GB/month**, thấp hơn break-even rất xa.

#### Kết luận security

Full VPCE no-NAT là security posture tốt nhất vì:
* Không cần outbound NAT cho AWS service APIs.
* Traffic tới AWS services đi private qua AWS network.
* Có thể dùng endpoint policy để giới hạn service/resource.
* Có security group trên interface endpoint ENI.

Nhưng với 10 interface endpoints × 2 AZ, fixed cost **$146/month** chỉ riêng VPCE là quá cao cho budget capstone khi traffic rất thấp.

#### Câu chốt để defend

**Chốt: Với scope CDO04 tại `us-west-2`, AI endpoint đã internal và AWS API traffic chỉ khoảng 12GB/tháng, giải pháp tối ưu cost-security cho nền tảng là giữ thiết kế hiện tại: 1 zonal NAT Gateway kết hợp S3 + DynamoDB Gateway Endpoints; full VPCE no-NAT là phương án security-first/production hardening nhưng không tối ưu cost cho capstone vì cần 10 interface endpoints multi-AZ và chỉ break-even ở mức multi-TB/tháng.**

#### Production hardening path

Nếu mentor hoặc panel yêu cầu security cao hơn, thứ tự nâng cấp hợp lý:
1. Giữ S3 + DynamoDB Gateway Endpoints như baseline.
2. Thêm interface endpoints theo traffic/security priority:
   * `logs` và `monitoring` nếu muốn CloudWatch private path.
   * `timestream.ingest-<cell>` và `timestream.query-<cell>` nếu muốn TSDB hot path private.
   * `sqs` và `sns` nếu muốn queue/alert path private.
   * `secretsmanager` và `kms` nếu muốn secret/decrypt path private.
   * `ecr.api` và `ecr.dkr` nếu muốn image pull no-NAT.
3. Khi đã có đủ endpoints cho toàn bộ runtime path, mới bỏ NAT hoàn toàn.
4. Nếu chỉ cần HA egress nhưng chưa cần private-only, nâng từ 1 zonal NAT lên 2 NAT Gateways, mỗi AZ một NAT.

---

## 5. Cost vs alternatives (cùng task force TF4)

| Angle | $/monitored-service-unit/month (50 units) | Trade-off chính |
|---|---|---|
| **CDO 04 — TSDB-backed Control Plane** (nhóm này) | **~$17.02** | Dữ liệu Timestream tính phí minh bạch, rẻ ở quy mô nhỏ. Rủi ro chi phí nằm ở NAT Gateway cố định. |
| **CDO khác — Lakehouse angle** (S3 + Athena) | ~$5.00 – $8.00 | S3 rẻ nhưng Athena tính phí theo dung lượng quét dữ liệu (data scan) của mỗi câu truy vấn. Khó kiểm soát chi phí nếu truy vấn nhiều và latency cao. |
| **CDO khác — Managed Observability** (Prometheus/Grafana) | ~$6.00 – $10.00 | Tốn chi phí vận hành, cài đặt cấu hình VM (EC2) chạy Prometheus liên tục 24/7 và bản quyền Grafana Cloud. |

---

## 6. 2-week capstone budget estimate

Dưới đây là dự báo chi phí thực tế cho **2 tuần chạy thử nghiệm Capstone** (môi trường Staging/Demo):

| Service | Forecast 2 tuần | Ghi chú |
|---|---|---|
| ECS Fargate (API + Worker + AI) | ~$45.05 | 5 tasks chạy Fargate luôn bật (365 giờ × $0.024685/task-hour) |
| Application Load Balancer | ~$11.14 | Chi phí cố định cho ALB (365 giờ × $0.0225/giờ) + LCU |
| NAT Gateway | ~$16.43 | Chi phí cố định theo giờ chạy thực tế của NAT (365 giờ × $0.045/giờ tại `us-west-2`) |
| NAT Data Processing | ~$0.27 | Khoảng 6 GB processing qua NAT cho 2 tuần × $0.045/GB |
| Amazon Timestream | ~$2.50 | Phân bổ 2 tuần chạy demo/ghi dữ liệu, lưu trữ và truy vấn |
| DynamoDB | ~$0.05 | Ghi audit log thực tế cho 2 tuần |
| CloudWatch & SNS | ~$4.00 | Dashboard + alarm + log ingestion |
| S3 | ~$0.18 | Logs + evidence buffer storage |
| Secrets Manager & KMS | ~$1.70 | 3 secrets + 2 KMS keys dùng cho 2 tuần |
| EventBridge & SQS | ~$0.03 | SQS queues + scheduler triggers |
| **Total forecast 2 tuần** | **~$81.35** | Còn dư **~$118.65** trong ngân sách $200 để chạy load test |

### 6.1 Measured actual (Pack #2 — fill in W12)

| Service | Forecast | Actual | Delta |
|---|---|---|---|
| ECS Fargate | $45.05 | - | - |
| Application Load Balancer | $11.14 | - | - |
| NAT Gateway | $16.43 | - | - |
| NAT Data Processing | $0.27 | - | - |
| Timestream | $2.50 | - | - |
| DynamoDB | $0.05 | - | - |
| CloudWatch | $4.00 | - | - |
| Khác (S3/Secrets/SQS) | $1.91 | - | - |
| **Total** | **$81.35** | **-** | **-** |

### 6.2 Per-monitored-service-unit actual (Pack #2 — fill in W12)

| Monitored service unit test | Service | $/day forecast | Extrapolate $/month |
|---|---|---|---|
| Unit-1 | `payment-gateway` | ~$1.94 | ~$58 |
| Unit-2 | `ledger-service` | ~$1.94 | ~$58 |
| Unit-3 | `kyc-worker` | ~$1.94 | ~$58 |

### 6.3 Cost-per-correct-decision (Pack #2 — joint with AI eval)

| Metric | Forecast | Actual |
|---|---|---|
| Total prediction calls trong capstone | ~3,456 (8,640 × 2 tuần / 5) | - |
| Correct decisions (catch ≥80%) | ~2,765 | - |
| Total platform cost | ~$81.35 | - |
| **Cost per correct decision** | **~$0.029** | **-** |

---

## 7. Cost guardrails

### 7.1 Ngưỡng cảnh báo chi phí (70/90/100 Policy)

*Quy tắc cốt lõi*: **Không bao giờ tắt Audit Log (DynamoDB) và cơ chế Fail-open Fallback** ở bất kỳ ngưỡng chi phí nào để đảm bảo hệ thống không mất hoàn toàn giám sát.

*   **Ngưỡng 70% ($140/tháng)**: Bắn cảnh báo qua SNS tới Email/Slack của Infra Owner. Rà soát tần suất gọi AI của Worker, đảm bảo không cho phép tăng prediction cadence dày hơn 5 phút/lần nếu chưa có approval.
*   **Ngưỡng 90% ($180/tháng)**: Review khẩn cấp. Tự động giảm log verbosity (chuyển từ `DEBUG` sang `WARN`) để giảm chi phí ghi log của CloudWatch. Rà soát lại Timestream query pattern, đảm bảo câu truy vấn bắt buộc phải filter đầy đủ theo `tenant_id`, `service_id`, `metric_type` và time window (align với ADR-004). Giảm tần suất chạy kịch bản load test giả lập.
*   **Ngưỡng 100% ($200/tháng)**: Kích hoạt **Circuit Breaker** – lập tức tạm dừng (pause) toàn bộ luồng chạy Synthetic Load Test (k6/Locust) và các prediction job không quan trọng. Các prediction/fallback decision quan trọng vẫn tiếp tục được ghi audit. Cơ chế fail-open static threshold fallback không bị tắt.

### 7.2 Cấu hình Terraform Budgets

```hcl
resource "aws_budgets_budget" "platform_budget" {
  name         = "tf4-cdo04-platform-budget"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 70
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 90
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 100
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }
}
```

### 7.3 Per-monitored-service-unit quota enforcement

- API entry layer rate limit: 1,000 req/min per monitored service unit (đây là giả định thiết kế - assumption cho W12, được enforced tại Telemetry API)
- Prediction cadence lock: không cho phép caller request prediction dày hơn 5 phút/lần per service
- Timestream write quota: reject ingest nếu write rate > 2× baseline expected per monitored service unit (để đảm bảo tối ưu hóa chi phí và align với ADR-004)

---

## 8. Cost recommendations for production

*   **Sử dụng NAT Instance (Tùy chọn - Optional)**: Sử dụng 1 EC2 instance siêu nhỏ (ví dụ `t3.nano` hoặc `t4g.nano`) tự cấu hình NAT thay vì AWS NAT Gateway dịch vụ. Đây là tùy chọn (optional) dành riêng cho môi trường non-production hoặc cost-sensitive sandbox để tiết kiệm chi phí, không khuyến nghị làm mặc định cho môi trường Production thực tế nhằm đảm bảo tính sẵn sàng cao (High Availability) và thông lượng mạng lớn.
*   **AWS Savings Plans**: Đăng ký gói cam kết sử dụng Compute 1 năm cho Fargate để giảm 20-30% chi phí.
*   **Chuyển đổi sang DynamoDB Provisioned Capacity**: Khi lượng truy cập đã ổn định và dự đoán được, chuyển DynamoDB sang Provisioned Capacity và cấu hình Auto-scaling để tiết kiệm chi phí hơn On-demand.

---

## Related documents

*   [`02_infra_design.md`](02_infra_design.md) — Sơ đồ kiến trúc hạ tầng chi tiết.
*   [`04_deployment_design.md`](04_deployment_design.md) — Kế hoạch CI/CD và triển khai.
*   [`07_test_eval_report.md`](07_test_eval_report.md) — Báo cáo test tải kiểm chứng giả định chi phí.
*   [`08_adrs.md`](08_adrs.md) — Hồ sơ quyết định kiến trúc: ADR-004 (Timestream), ADR-007 (DynamoDB audit store), và ADR-008 (NAT + Gateway Endpoints).
