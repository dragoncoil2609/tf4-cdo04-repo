# So sánh chi phí NAT Gateway, VPC Endpoint và hybrid endpoint cho CDO04

<!-- Status: Final monthly workload/cost decision
     Date updated: 2026-06-26 -->

Tài liệu này chốt lựa chọn **NAT Gateway vs VPC Endpoint vs hybrid NAT + VPCE** cho kiến trúc trong `02_infra_design.md`, sau khi AI Engine đã được host nội bộ trong cùng ECS Cluster/VPC và metric backend đã chuyển sang **Amazon Managed Service for Prometheus (AMP)**.

Mục tiêu của tài liệu này không chỉ trả lời “AMP nên đi qua NAT hay VPC Endpoint”, mà tính đầy đủ workload 1 tháng cho các AWS service mà private ECS tasks sẽ gọi, xác định break-even theo từng service, rồi chốt path tối ưu cost-security cho hệ thống.

## 1. Baseline và phạm vi tính

```text
Region: us-east-1 / US East (N. Virginia)
Month: 730 hours
Topology: 2 AZ, private ECS Fargate tasks, public ALB ingress
Runtime: Telemetry API + Prediction Worker + AI Engine in private subnets
AI endpoint: ECS Service Connect service name/path, không đi qua NAT hoặc VPCE
Metrics backend: AMP workspace
Gateway endpoints: S3 + DynamoDB
Budget target: <= $200/month platform baseline
```

Traffic được tính trong tài liệu này chỉ là traffic từ **private ECS tasks tới AWS service APIs** có thể đi qua NAT Gateway hoặc Interface VPC Endpoint. Không tính:

- Client → public ALB ingest traffic.
- Worker → AI Engine traffic, vì đi nội bộ qua ECS Service Connect.
- S3/DynamoDB endpoint processing, vì dùng Gateway Endpoint không có hourly/endpoint processing charge.
- Bản thân phí service như CloudWatch Logs ingest, SQS request, AMP samples, DynamoDB writes; các phí đó đã nằm trong `05_cost_analysis.md`. Tài liệu này chỉ so sánh **network path cost**.

## 2. Pricing đã dùng

Nguồn kiểm chứng:

- AWS VPC NAT Gateway pricing documentation: NAT Gateway tính phí theo giờ chạy và theo GB data processed; AWS khuyến nghị NAT cùng AZ hoặc NAT per AZ khi traffic cross-AZ lớn, và dùng VPC Endpoint cho AWS services nếu cost-effective.
- AWS PrivateLink pricing documentation: Interface Endpoint tính phí theo endpoint-hour trong từng AZ và theo GB processed; tier đầu tiên 1 PB/tháng là `$0.01/GB`.
- AWS Pricing/API evidence đã ghi trong `05_cost_analysis.md` và `misc/amp_migration_cost_estimate.md` cho `us-east-1`.

| Item | Giá tại `us-east-1` dùng cho planning |
|---|---:|
| NAT Gateway hourly | **$0.045 / NAT Gateway-hour** |
| NAT Gateway data processing | **$0.045 / GB processed** |
| Interface VPCE hourly | **$0.010 / endpoint-AZ-hour** |
| Interface VPCE data processing | **$0.010 / GB processed** cho tier đầu tiên |
| S3 Gateway Endpoint | **$0/hour, $0 endpoint processing** |
| DynamoDB Gateway Endpoint | **$0/hour, $0 endpoint processing** |

Vì topology chạy 2 AZ:

```text
1 interface endpoint service in 2 AZ
= 2 AZ × 730h × $0.010
= $14.60/month fixed
```

Saving data processing khi chuyển 1 GB từ NAT sang Interface VPCE:

```text
$0.045/GB - $0.010/GB = $0.035/GB
```

Break-even cho 1 endpoint service trong 2 AZ nếu NAT vẫn còn:

```text
$14.60 / $0.035 = 417.14 GB/month/service
```

Nghĩa là nếu giữ NAT, thêm 1 Interface VPCE chỉ tiết kiệm tiền khi service đó có **>417 GB/tháng** traffic chuyển khỏi NAT. Dưới mức này, VPCE là lựa chọn security/compliance, không phải cost-saving.

## 3. Workload 1 tháng của hệ thống

### 3.1 Telemetry và prediction workload

Từ `02_infra_design.md` và `05_cost_analysis.md`:

```text
Demo services: payment-gateway, ledger-service, kyc-worker = 3 services
Telemetry frequency: 1 sample/minute
Required AI signals: 7 metrics/service
Prediction cadence: every 5 minutes = 12 cycles/hour
AI lookback window: 120 minutes
```

Metric samples ingested vào AMP:

```text
7 metrics × 60 minutes × 24 hours × 30 days = 302,400 samples/service/month
3 services × 302,400 = 907,200 samples/month
```

Prediction cycles:

```text
3 services × 12 cycles/hour × 24 hours × 30 days
= 25,920 prediction jobs/month
```

Worker query samples từ AMP:

```text
Each prediction query ~= 7 metrics × 120 one-minute samples = 840 query samples
25,920 jobs × 840 = 21,772,800 query samples/month
```

AMP service charge cho demo scope vẫn ~`$0.00/month` trong baseline vì volume này nằm trong low/free-tier estimate đã ghi ở `05_cost_analysis.md`. Phần cần quyết định ở đây là **network path tới AMP**.

### 3.2 Network traffic qua NAT hoặc Interface VPCE

| Traffic source | AWS service/API path | Endpoint nếu no-NAT | Ước tính GB/tháng | Cách estimate | Current path |
|---|---|---|---:|---|---|
| AMP remote_write | AMP data-plane | `aps-workspaces` | **0.80** | 907,200 samples/month + request/compression overhead | NAT |
| AMP query/query_range | AMP data-plane | `aps-workspaces` | **2.20** | 25,920 prediction jobs × 120m window × 7 metrics/service; response/query overhead | NAT |
| CloudWatch Logs | CloudWatch Logs | `logs` | **6.00** | Current component table estimates small log ingest/storage; use ~6GB runtime log traffic as conservative network model | NAT |
| CloudWatch custom metrics | CloudWatch Metrics | `monitoring` | **0.20** | CPU/memory/fallback/AI latency/custom metric calls | NAT |
| SQS | SQS API | `sqs` | **0.20** | ~25,920 jobs/month, receive/delete/change visibility, small body | NAT |
| SNS | SNS API | `sns` | **0.05** | Only high-risk alerts | NAT |
| Secrets Manager | Secrets Manager API | `secretsmanager` | **0.05** | Task startup/refresh secrets | NAT |
| KMS | KMS API | `kms` | **0.05** | Direct runtime decrypt calls; managed at-rest encryption is not on ECS egress path | NAT |
| STS | STS API | `sts` | **~0.00** | Needed for private-only credential/SigV4 flows; data volume tiny | NAT if needed |
| ECR API/DKR control | ECR API + Docker Registry API | `ecr.api` + `ecr.dkr` | **0.30** | Metadata/auth/registry control calls for image deploy/replacement | NAT |
| ECR image layers | S3 backing path | S3 Gateway Endpoint | **2-5** | Image layer bytes; should route through S3 gateway endpoint | S3 Gateway Endpoint |
| S3 failure buffer/evidence/ALB logs | S3 | S3 Gateway Endpoint | **low/small** | Failure buffer, baseline, evidence export, ALB logs | S3 Gateway Endpoint |
| DynamoDB audit/policy | DynamoDB | DynamoDB Gateway Endpoint | **<0.10** | 25,920 audit writes + policy reads | DynamoDB Gateway Endpoint |
| Worker → AI Engine | ECS Service Connect | Not applicable | Not counted | Internal VPC service-to-service path | Service Connect |

Traffic chargeable through NAT or Interface VPCE:

```text
AMP remote_write/query      = 0.80 + 2.20 = 3.00 GB/month
CloudWatch logs/metrics     = 6.00 + 0.20 = 6.20 GB/month
SQS/SNS                     = 0.20 + 0.05 = 0.25 GB/month
Secrets/KMS/STS             = 0.05 + 0.05 + ~0 = 0.10 GB/month
ECR API/DKR control         = 0.30 GB/month
-------------------------------------------------------------
Subtotal                    = 9.85 GB/month
Planning rounded model      = 12.00 GB/month
```

Tài liệu này dùng **12 GB/month** để không under-estimate.

## 4. Endpoint set nếu bỏ NAT hoàn toàn

Nếu chọn **no-NAT**, tất cả AWS API traffic từ private ECS tasks phải đi qua Gateway Endpoint hoặc Interface Endpoint.

### 4.1 Gateway endpoints bắt buộc và giữ trong mọi phương án

| Endpoint | Type | Dùng bởi | Cost decision |
|---|---|---|---|
| `com.amazonaws.us-east-1.s3` | Gateway | ECR image layers, S3 failure buffer, ALB logs, evidence export | **Always keep** vì endpoint construct không tính hourly/processing |
| `com.amazonaws.us-east-1.dynamodb` | Gateway | Prediction Worker audit/policy DB | **Always keep** vì endpoint construct không tính hourly/processing |

### 4.2 Interface endpoints tối thiểu cho no-NAT runtime

| # | Endpoint service name | Dùng bởi | Lý do cần nếu không có NAT |
|---:|---|---|---|
| 1 | `com.amazonaws.us-east-1.ecr.api` | ECS execution role | ECR auth/metadata API |
| 2 | `com.amazonaws.us-east-1.ecr.dkr` | ECS execution role | Docker Registry API |
| 3 | `com.amazonaws.us-east-1.logs` | ECS execution role + app | CloudWatch Logs stream/write |
| 4 | `com.amazonaws.us-east-1.monitoring` | Telemetry API / Worker / AI | CloudWatch custom metrics |
| 5 | `com.amazonaws.us-east-1.secretsmanager` | ECS tasks | Runtime secrets/config |
| 6 | `com.amazonaws.us-east-1.kms` | ECS tasks / SDK | Runtime decrypt where direct KMS API is used |
| 7 | `com.amazonaws.us-east-1.sqs` | Prediction Worker | Receive/delete prediction jobs + DLQ interactions |
| 8 | `com.amazonaws.us-east-1.sns` | Prediction Worker | Publish high-risk alerts |
| 9 | `com.amazonaws.us-east-1.aps-workspaces` | Telemetry API / collector / Worker | AMP remote_write/query/query_range data plane |
| 10 | `com.amazonaws.us-east-1.sts` | SigV4 clients/collectors | Regional STS for private-only credential flows |

Optional endpoint:

| Endpoint | Khi nào cần | Extra fixed cost in 2 AZ |
|---|---|---:|
| `com.amazonaws.us-east-1.aps` | Runtime trong VPC gọi AMP workspace/control-plane APIs. Terraform/CI ngoài runtime không cần endpoint này. | **+$14.60/month** |

Không đưa vào baseline no-NAT: `events`, `ecs`, `ecs-agent`, `ecs-telemetry`, `ssm`, `ssmmessages`, `ec2messages`, `xray`, trừ khi architecture bật thêm ECS Exec, SSM Parameter Store, X-Ray hoặc runtime gọi EventBridge APIs trực tiếp.

## 5. Công thức cost tổng quát

Ký hiệu:

```text
G = total GB/month đi qua NAT hoặc Interface VPCE
N = số Interface Endpoint services
AZ = 2
```

### 5.1 Current baseline: 1 zonal NAT + S3/DynamoDB Gateway Endpoints

```text
Cost = 1 × 730 × $0.045 + G × $0.045
     = $32.85 + G × $0.045
```

Tại `G = 12`:

```text
$32.85 + 12 × $0.045 = $33.39/month
```

### 5.2 HA NAT: 2 NAT Gateways + S3/DynamoDB Gateway Endpoints

```text
Cost = 2 × 730 × $0.045 + G × $0.045
     = $65.70 + G × $0.045
```

Tại `G = 12`:

```text
$65.70 + 12 × $0.045 = $66.24/month
```

### 5.3 Full no-NAT: 10 Interface Endpoints × 2 AZ + Gateway Endpoints

```text
Cost = 10 endpoints × 2 AZ × 730 × $0.010 + G × $0.010
     = $146.00 + G × $0.010
```

Tại `G = 12`:

```text
$146.00 + 12 × $0.010 = $146.12/month
```

Nếu thêm `aps` control-plane endpoint:

```text
11 endpoints × 2 AZ × 730 × $0.010 + 12 × $0.010
= $160.60 + $0.12
= $160.72/month
```

### 5.4 Hybrid NAT + selected Interface VPCE

Khi NAT vẫn còn, thêm VPCE cho service `E` chỉ chuyển traffic của service đó từ NAT data processing sang PrivateLink data processing. NAT hourly vẫn phải trả.

```text
Hybrid delta vs current NAT baseline
= E × $14.60 + shifted_GB × $0.010 - shifted_GB × $0.045
= E × $14.60 - shifted_GB × $0.035
```

Hybrid endpoint group chỉ tiết kiệm tiền nếu:

```text
shifted_GB > E × 417.14 GB/month
```

Với current workload, không endpoint group nào gần break-even; hybrid chỉ nên dùng nếu cần security/compliance.

## 6. Service-by-service cost, break-even và quyết định

### 6.1 Bảng theo từng service path

| Service path | Endpoint(s) nếu private | Endpoint count | Current GB/month | NAT data cost/month | Hybrid VPCE cost/month nếu thêm endpoint | Delta vs giữ NAT | Break-even GB/month | Decision |
|---|---|---:|---:|---:|---:|---:|---:|---|
| AMP data-plane remote_write + query | `aps-workspaces` | 1 | **3.00** | `$0.14` | `$14.60 + 3×0.010 = $14.63` | **+$14.50** | **417 GB** | **Giữ NAT trong MVP**; đây là endpoint hardening đầu tiên nếu cần private AMP |
| CloudWatch Logs | `logs` | 1 | **6.00** | `$0.27` | `$14.60 + 6×0.010 = $14.66` | **+$14.39** | **417 GB** | Giữ NAT; endpoint là security-only hiện tại |
| CloudWatch Metrics | `monitoring` | 1 | **0.20** | `$0.01` | `$14.60 + 0.2×0.010 = $14.60` | **+$14.59** | **417 GB** | Giữ NAT |
| SQS jobs/DLQ | `sqs` | 1 | **0.20** | `$0.01` | `$14.60 + 0.2×0.010 = $14.60` | **+$14.59** | **417 GB** | Giữ NAT |
| SNS alert publish | `sns` | 1 | **0.05** | `<$0.01` | `$14.60 + 0.05×0.010 = $14.60` | **+$14.60** | **417 GB** | Giữ NAT |
| Secrets Manager | `secretsmanager` | 1 | **0.05** | `<$0.01` | `$14.60 + 0.05×0.010 = $14.60` | **+$14.60** | **417 GB** | Giữ NAT |
| KMS runtime API | `kms` | 1 | **0.05** | `<$0.01` | `$14.60 + 0.05×0.010 = $14.60` | **+$14.60** | **417 GB** | Giữ NAT |
| STS regional credential flow | `sts` | 1 | **~0.00** | `~$0.00` | `$14.60` | **+$14.60** | **417 GB** | Chỉ thêm nếu private-only/no-NAT hoặc SigV4 flow bắt buộc không đi public endpoint |
| ECR API + Docker Registry | `ecr.api` + `ecr.dkr` | 2 | **0.30** | `$0.01` | `$29.20 + 0.3×0.010 = $29.20` | **+$29.19** | **834 GB** | Giữ NAT cho control; S3 layer bytes đi qua S3 Gateway Endpoint |
| S3 evidence/failure buffer/ECR layers | S3 Gateway Endpoint | 0 paid interface | **2-5+** | `$0 NAT processing` | `$0 endpoint processing` | `$0` | N/A | **Always Gateway Endpoint** |
| DynamoDB audit/policy | DynamoDB Gateway Endpoint | 0 paid interface | **<0.10** | `$0 NAT processing` | `$0 endpoint processing` | `$0` | N/A | **Always Gateway Endpoint** |
| Worker → AI Engine | ECS Service Connect | N/A | N/A | `$0 NAT/VPCE` | `$0 NAT/VPCE` | `$0` | N/A | **Always internal Service Connect** |

### 6.2 Endpoint group break-even

| Endpoint group | Endpoints | Fixed/month in 2 AZ | Current shifted GB/month | Current hybrid delta vs NAT | Break-even GB/month | Decision |
|---|---:|---:|---:|---:|---:|---|
| AMP private data-plane only | 1 | `$14.60` | **3.00** | **+$14.50** | **417 GB** | Optional security hardening, not cost-saving |
| AMP + CloudWatch Logs | 2 | `$29.20` | **9.00** | **+$28.89** | **834 GB** | Not cost-saving |
| AMP + CloudWatch Logs + Metrics | 3 | `$43.80` | **9.20** | **+$43.48** | **1,251 GB** | Not cost-saving |
| SQS + SNS private queue/alert path | 2 | `$29.20` | **0.25** | **+$29.19** | **834 GB** | Not cost-saving |
| Secrets + KMS + STS | 3 | `$43.80` | **0.10** | **+$43.80** | **1,251 GB** | Security-only |
| ECR API + ECR DKR | 2 | `$29.20` | **0.30** | **+$29.19** | **834 GB** | Security-only; not needed for MVP cost |
| Full no-NAT minimum | 10 | `$146.00` | **12.00** | If NAT still kept: **+$145.58** | **4,171 GB** data-only | Only makes sense if NAT is removed or compliance requires |

## 7. Scenario comparison

### 7.1 Network path cost at current 12 GB/month

| Scenario | Formula | Monthly network path cost | Delta vs current |
|---|---:|---:|---:|
| Current: 1 zonal NAT + S3/DDB Gateway EP | `$32.85 + 12×$0.045` | **$33.39** | Baseline |
| HA NAT: 2 NAT + S3/DDB Gateway EP | `$65.70 + 12×$0.045` | **$66.24** | **+$32.85** |
| Hybrid: current + AMP `aps-workspaces` | `$33.39 + $14.60 - 3×$0.035` | **$47.89** | **+$14.50** |
| Hybrid: current + AMP + CloudWatch Logs | `$33.39 + $29.20 - 9×$0.035` | **$62.28** | **+$28.89** |
| Hybrid: current + AMP + CloudWatch Logs + Metrics | `$33.39 + $43.80 - 9.2×$0.035` | **$76.87** | **+$43.48** |
| Full no-NAT: 10 VPCE + Gateway EP | `$146.00 + 12×$0.010` | **$146.12** | **+$112.73** |
| Full no-NAT + AMP control endpoint: 11 VPCE + Gateway EP | `$160.60 + 12×$0.010` | **$160.72** | **+$127.33** |

### 7.2 Sensitivity theo traffic tổng

| Model | Formula | 0 GB | 12 GB realistic | 100 GB | 500 GB | 1,000 GB | 2,300 GB | 3,233 GB | 5,000 GB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 NAT + Gateway EP | `$32.85 + G×$0.045` | `$32.85` | **`$33.39`** | `$37.35` | `$55.35` | `$77.85` | `$136.35` | `$178.34` | `$257.85` |
| 2 NAT + Gateway EP | `$65.70 + G×$0.045` | `$65.70` | **`$66.24`** | `$70.20` | `$88.20` | `$110.70` | `$169.20` | `$211.19` | `$290.70` |
| Full no-NAT 10 VPCE | `$146.00 + G×$0.010` | `$146.00` | **`$146.12`** | `$147.00` | `$151.00` | `$156.00` | `$169.00` | `$178.33` | `$196.00` |

Break-even:

```text
Full no-NAT vs 1 NAT:
(146.00 - 32.85) / (0.045 - 0.010)
= 113.15 / 0.035
= 3,232.86 GB/month

Full no-NAT vs 2 NAT:
(146.00 - 65.70) / (0.045 - 0.010)
= 80.30 / 0.035
= 2,294.29 GB/month
```

Interpretation:

- Ở current workload **12 GB/month**, full VPCE đắt hơn current NAT khoảng **$112.73/month**.
- Full no-NAT chỉ rẻ hơn 1 NAT khi AWS API egress đạt khoảng **3.2 TB/month**.
- Full no-NAT chỉ rẻ hơn HA 2 NAT khi AWS API egress đạt khoảng **2.3 TB/month**.

## 8. Cross-AZ caveat cho 1 zonal NAT

Current baseline dùng 1 NAT Gateway trong 1 AZ, trong khi ECS tasks chạy 2 AZ. Nếu task ở AZ còn lại route qua NAT ở AZ đặt NAT, có thể phát sinh cross-AZ data transfer charge và NAT không HA theo AZ.

Với workload hiện tại:

```text
Total chargeable NAT/interface traffic = 12 GB/month
Nếu 50% cross-AZ ~= 6 GB/month
Ngay cả với planning rate ~$0.01/GB, phần này chỉ ở mức vài cents/tháng
```

Vì vậy cross-AZ charge không thay đổi quyết định cost hiện tại. Nhưng điểm yếu HA vẫn tồn tại: nếu AZ chứa NAT gặp sự cố, private egress qua NAT có thể bị ảnh hưởng. Production hardening có 2 hướng:

1. **HA egress:** thêm NAT thứ 2, mỗi AZ một NAT, cost +`$32.85/month` fixed.
2. **Private-only egress:** thêm đầy đủ Interface VPCE rồi bỏ NAT, cost +`$112.73/month` tại workload hiện tại nhưng posture tốt nhất.

## 9. Security comparison

| Model | Cost at 12GB/month | Security posture | Egress HA | Nhận xét |
|---|---:|---|---|---|
| 1 zonal NAT + S3/DDB Gateway EP | **$33.39** | Trung bình-khá | Không HA cho NAT egress | Rẻ nhất; S3/DDB private; AI internal; AWS APIs còn đi HTTPS qua NAT |
| 2 NAT + S3/DDB Gateway EP | **$66.24** | Trung bình-khá | Có HA theo AZ | Tốt hơn cho production HA nhưng không private-only |
| Hybrid: add AMP `aps-workspaces` | **$47.89** | Tốt hơn cho metric data-plane | NAT vẫn còn | Chỉ đáng làm nếu reviewer/compliance yêu cầu AMP private path |
| Hybrid: add AMP + CloudWatch Logs | **$62.28** | Tốt hơn cho observability path | NAT vẫn còn | Security hardening có thể defend, nhưng vẫn không cost-saving |
| Full no-NAT 10 VPCE | **$146.12** | Tốt nhất | Endpoint per AZ | Private-only cho runtime AWS APIs; fixed cost cao cho capstone |

Full VPCE/no-NAT có security posture tốt nhất vì:

- Không cần outbound NAT cho runtime AWS API traffic.
- Traffic tới AWS services đi private qua AWS network.
- Có thể dùng endpoint policy và endpoint security group để giới hạn service/resource.

Nhưng với current workload thấp, lợi ích này không đến từ cost saving mà từ security/compliance.

## 10. Final decision

### 10.1 Quyết định cost/security tối ưu cho CDO04 MVP

**Chốt baseline:**

```text
1 zonal NAT Gateway
+ S3 Gateway Endpoint
+ DynamoDB Gateway Endpoint
+ no Interface VPCE in MVP baseline
```

Network path cost:

```text
~$33.39/month at 12 GB/month
```

Lý do:

1. Current AWS API traffic chỉ khoảng **12 GB/month**, thấp hơn rất xa break-even của VPCE.
2. Full no-NAT cần ít nhất **10 Interface Endpoints × 2 AZ = $146/month fixed**, làm network path đắt hơn current NAT **+$112.73/month**.
3. Platform baseline trong `05_cost_analysis.md` là **~$158.16/month**, và với 20% ops buffer là **~$189.79/month**. Buffer còn khoảng **$10.21** trước hard budget `$200/month`, nên thêm AMP VPCE **+$14.50/month** đã có thể phá buffer nếu không giảm chỗ khác.
4. S3 và DynamoDB đã dùng Gateway Endpoint miễn phí hourly/processing, nên hai đường dữ liệu quan trọng nhất cho evidence/audit không đi NAT.
5. AI prediction call không đi NAT/VPCE vì Worker → AI Engine đi qua ECS Service Connect nội bộ VPC.

### 10.2 Trả lời riêng câu “AMP qua NAT hay VPCE?”

**AMP đi qua NAT trong MVP.**

Tính toán:

```text
AMP traffic = remote_write 0.8 GB + query/query_range 2.2 GB = 3.0 GB/month
NAT data cost for AMP = 3 × $0.045 = $0.135/month
AMP Interface VPCE cost = $14.60 fixed + 3 × $0.010 = $14.63/month
Delta = +$14.50/month
Break-even = 417 GB/month for aps-workspaces endpoint
```

Vì current AMP traffic chỉ khoảng **3 GB/month**, `aps-workspaces` endpoint là **security hardening**, không phải cost optimization. Nếu hội đồng/mentor yêu cầu private-only metric data-plane, có thể thêm `aps-workspaces` trước tiên, nhưng cần ghi rõ nó tăng cost khoảng **+$14.50/month** và có thể làm mất 20% ops buffer nếu không tối ưu thành phần khác.

### 10.3 Quyết định theo từng service

| Service | Final path now | Lý do |
|---|---|---|
| S3 | **Gateway Endpoint** | Free endpoint construct, dùng cho ECR layers/failure buffer/evidence |
| DynamoDB | **Gateway Endpoint** | Free endpoint construct, audit/policy private |
| AMP `remote_write/query_range` | **NAT now; optional `aps-workspaces` later** | 3GB/month thấp hơn 417GB break-even; endpoint là security-only |
| CloudWatch Logs | **NAT now** | 6GB/month thấp hơn 417GB break-even |
| CloudWatch Metrics | **NAT now** | 0.2GB/month rất nhỏ |
| SQS/SNS | **NAT now** | Traffic rất nhỏ; endpoint không tiết kiệm cost |
| Secrets Manager/KMS/STS | **NAT now** | Traffic rất nhỏ; thêm endpoint chỉ khi private-only/no-NAT |
| ECR API/DKR | **NAT now + S3 Gateway for layers** | Control traffic nhỏ; layer bytes qua S3 Gateway Endpoint |
| AI Worker → AI Engine | **ECS Service Connect** | Không dùng NAT/VPCE |

## 11. Production hardening path

Nếu cần nâng posture sau MVP, thứ tự hợp lý là:

1. **Giữ S3 + DynamoDB Gateway Endpoints** trong mọi phương án.
2. Nếu câu hỏi security tập trung vào metrics, thêm **`aps-workspaces`** trước.
   - Added cost: khoảng **+$14.50/month** tại current workload.
   - Benefit: AMP remote_write/query private path.
3. Nếu muốn private observability path, thêm **`logs`**, sau đó **`monitoring`**.
   - AMP + logs added cost: khoảng **+$28.89/month**.
   - AMP + logs + monitoring added cost: khoảng **+$43.48/month**.
4. Nếu muốn private queue/alert path, thêm **`sqs` + `sns`**.
5. Nếu muốn no-NAT runtime thật sự, thêm **`secretsmanager` + `kms` + `sts` + `ecr.api` + `ecr.dkr`** rồi mới bỏ NAT.
6. Nếu chỉ cần egress HA nhưng chưa cần private-only, dùng **2 NAT Gateways** thay vì full VPCE.

Không nên bỏ NAT trước khi đủ endpoint cho mọi runtime AWS API path, vì ECS tasks sẽ mất đường gọi tới ECR, CloudWatch, Secrets/KMS, SQS/SNS, AMP hoặc STS tùy code path.

## 12. Defense statement

**Với CDO04 tại `us-east-1`, workload AWS API từ private ECS tasks chỉ khoảng 12GB/tháng. S3 và DynamoDB đã đi qua Gateway Endpoint miễn phí, AI path đi nội bộ qua ECS Service Connect, còn AMP/CloudWatch/SQS/SNS/Secrets/KMS/ECR traffic đều rất thấp. Vì vậy phương án tối ưu cost-security cho MVP là giữ 1 zonal NAT Gateway + S3/DynamoDB Gateway Endpoints. AMP `aps-workspaces` Interface Endpoint là hardening option đầu tiên nếu cần private metric data-plane, nhưng hiện tăng khoảng $14.50/tháng và chỉ break-even khi AMP traffic vượt ~417GB/tháng. Full no-NAT 10 Interface Endpoints chỉ tối ưu cost khi tổng AWS API traffic vượt ~3.2TB/tháng so với 1 NAT, hoặc khi compliance yêu cầu private-only bất kể chi phí.**
