# So sánh chi phí NAT Gateway và VPC Endpoint cho CDO04

<!-- Status: Synced with AMP/us-east-1 baseline
     Date updated: 2026-06-26 -->

Tài liệu này chốt lại lựa chọn giữa **NAT Gateway** và **VPC Endpoint** cho kiến trúc trong `02_infra_design.md` sau khi AI Engine đã được host nội bộ trong cùng ECS Cluster/VPC và metric backend đã chuyển sang **Amazon Managed Service for Prometheus (AMP)**.

Phạm vi tính toán đã chốt:

```text
Region: us-east-1 / US East (N. Virginia)
Topology: Multi-AZ, 2 private subnets/AZ cho ECS Fargate
Runtime: Telemetry API + Prediction Worker + AI Engine trong private subnets
AI endpoint: ECS Service Connect service name/path, không đi qua NAT hoặc VPCE
Metrics backend: AMP workspace; MVP data-plane access qua NAT, PrivateLink là hardening option
Month: 730 hours
```

## 1. Nguồn kiểm chứng

Thông tin bên dưới được kiểm tra bằng AWS MCP, AWS Pricing API và tài liệu AWS chính thức trong quá trình đánh giá migration `us-east-1` + AMP.

### 1.1 NAT Gateway pricing tại `us-east-1`

AWS Pricing API trả về cho `AmazonEC2`, location `US East (N. Virginia)`, group `NGW:NatGateway`:

| Item | Giá |
|---|---:|
| NAT Gateway hourly | **$0.045 / NAT Gateway-hour** |
| NAT Gateway data processing | **$0.045 / GB processed** |

Ghi chú:

- NAT Gateway tính phí theo giờ chạy của từng NAT Gateway.
- NAT Gateway tính thêm data processing theo GB.
- Nếu private subnet ở AZ khác route qua một NAT Gateway đặt ở một AZ duy nhất, có thể phát sinh thêm cross-AZ data transfer charge. Với traffic demo của CDO04, phần này rất nhỏ nhưng là điểm yếu HA/security của zonal NAT.

### 1.2 Interface VPC Endpoint / AWS PrivateLink pricing tại `us-east-1`

Interface endpoint estimate giữ cùng đơn giá planning đã dùng trong migration analysis:

| Item | Giá |
|---|---:|
| Interface VPCE hourly | **$0.010 / endpoint-AZ-hour** |
| Interface VPCE data processing | **$0.010 / GB processed** cho first 1 PB/tháng |

Ghi chú:

- Interface endpoint được tính theo **mỗi endpoint trong mỗi AZ**.
- Multi-AZ 2 AZ nghĩa là 1 service endpoint = 2 endpoint-AZ-hour streams.
- VPCE data processing rẻ hơn NAT data processing, nhưng fixed hourly cost tăng nhanh nếu cần nhiều endpoint.

### 1.3 Gateway VPC Endpoint

Gateway Endpoint dùng cho:

```text
S3
DynamoDB
```

Cost model:

```text
S3 Gateway Endpoint       = $0/hour, $0/GB endpoint processing
DynamoDB Gateway Endpoint = $0/hour, $0/GB endpoint processing
```

Gateway Endpoint là lựa chọn mặc định cho CDO04 vì S3 failure buffer/evidence export và DynamoDB audit/policy không cần đi qua NAT.

### 1.4 AMP endpoint correction

AMP supports interface VPC endpoints for private connectivity:

```text
com.amazonaws.us-east-1.aps-workspaces   # Prometheus-compatible data plane: remote_write/query/query_range
com.amazonaws.us-east-1.aps              # workspace/control-plane APIs if needed
```

Ý nghĩa với CDO04:

- Telemetry API / collector remote-writes samples to AMP → needs `aps-workspaces` if no NAT.
- Prediction Worker queries `query_range`/PromQL → needs `aps-workspaces` if no NAT.
- If private-only SigV4 flows are required without NAT, also plan an STS interface endpoint and configure regional STS endpoints.

## 2. Endpoint set đầy đủ nếu bỏ NAT hoàn toàn

Nếu CDO04 chọn mô hình **no NAT**, toàn bộ AWS API traffic từ private ECS tasks phải đi qua Gateway Endpoint hoặc Interface Endpoint.

### 2.1 Gateway endpoints bắt buộc, không tính hourly

| Endpoint | Type | Dùng bởi | Lý do |
|---|---|---|---|
| `com.amazonaws.us-east-1.s3` | Gateway | ECS/ECR image layer pull, S3 failure buffer, ALB logs, evidence export | S3 gateway endpoint free, giảm NAT data processing |
| `com.amazonaws.us-east-1.dynamodb` | Gateway | Prediction Worker | Audit log + service policy DB |

### 2.2 Interface endpoints nếu no-NAT runtime

Với workload hiện tại, private-only runtime cần ít nhất 10 interface endpoints trong 2 AZ:

| # | Endpoint service name | Dùng bởi | Vì sao cần nếu không có NAT |
|---:|---|---|---|
| 1 | `com.amazonaws.us-east-1.ecr.api` | ECS execution role | Gọi ECR API để lấy image metadata/auth flow |
| 2 | `com.amazonaws.us-east-1.ecr.dkr` | ECS execution role | Docker Registry API khi pull image |
| 3 | `com.amazonaws.us-east-1.logs` | ECS execution role + app | Gửi container logs vào CloudWatch Logs |
| 4 | `com.amazonaws.us-east-1.monitoring` | Telemetry API / Worker / AI | Gửi custom metrics, health/fallback/AI latency metrics vào CloudWatch Metrics |
| 5 | `com.amazonaws.us-east-1.secretsmanager` | ECS tasks | Đọc runtime secrets/config của platform và AI Engine |
| 6 | `com.amazonaws.us-east-1.kms` | ECS tasks / AWS SDK | KMS decrypt cho secrets/config hoặc app-level encrypted payload nếu gọi trực tiếp |
| 7 | `com.amazonaws.us-east-1.sqs` | Prediction Worker | Receive/delete prediction jobs và DLQ interactions |
| 8 | `com.amazonaws.us-east-1.sns` | Prediction Worker | Publish high-risk alerts |
| 9 | `com.amazonaws.us-east-1.aps-workspaces` | Telemetry API / collector / Worker | AMP remote_write/query/query_range data plane |
| 10 | `com.amazonaws.us-east-1.sts` | SigV4 clients/collectors | Regional STS for private-only credential flows |

Optional:

| Endpoint | Lý do không đưa vào cost baseline |
|---|---|
| `com.amazonaws.us-east-1.aps` | Chỉ cần nếu workspace/control-plane APIs được gọi từ private runtime. Terraform/CI có thể chạy ngoài VPC. |
| `events` / EventBridge | EventBridge Scheduler là regional managed service gửi message vào SQS, không chạy trong VPC. |
| `ecs`, `ecs-agent`, `ecs-telemetry` | CDO04 không chạy ECS control-plane calls từ app container. |
| `ssm`, `ssmmessages`, `ec2messages` | Chỉ cần nếu dùng SSM Parameter Store hoặc ECS Exec. |
| `xray` | Chưa nằm trong observability baseline. |

## 3. Traffic model gần đúng từ infra design

Dựa trên `02_infra_design.md`, traffic đi qua NAT hoặc interface VPCE chỉ là traffic từ **private ECS tasks** tới AWS service APIs. AI call nội bộ `Worker → AI Engine` đi qua ECS Service Connect trong VPC, không đi NAT/VPCE. Ingest từ client vào public ALB cũng không tính vào NAT/VPCE.

Giả định workload đã chốt:

```text
3 demo services
Telemetry frequency: 1 phút
Prediction cadence: 5 phút
Prediction cycles: 3 services × 12 cycles/hour × 24 × 30 = 25,920 jobs/tháng
Metric volume: khoảng 907,200 AMP samples/tháng theo AI required signals
CloudWatch log cost estimate hiện tại: khoảng $3 log ingest/storage trong component table
```

Ước tính traffic AWS API hàng tháng:

| Traffic source | Đi đâu | Có đi NAT trong giải pháp hiện tại? | Có đi VPCE trong no-NAT? | Ước tính GB/tháng | Cách estimate |
|---|---|---:|---:|---:|---|
| AMP remote_write | AMP data-plane API | Có | `aps-workspaces` | ~0.8 GB | ~907k samples/month + request/compression overhead |
| AMP query_range | AMP data-plane API | Có | `aps-workspaces` | ~2.2 GB | 25,920 jobs × 120m window × 7 metrics/service, response aggregate/raw window nhỏ |
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
AMP remote_write/query ~3.0 GB/month
CloudWatch             ~6.2 GB/month
SQS/SNS                ~0.25 GB/month
Secrets/KMS            ~0.10 GB/month
ECR control            ~0.30 GB/month
--------------------------------
Estimated total        ~9.85 GB/month
Rounded model          10 GB/month
Conservative           12 GB/month
```

Tài liệu này dùng **12 GB/tháng** làm traffic model để không under-estimate.

## 4. Công thức tính cho 2 AZ tại `us-east-1`

Ký hiệu:

```text
G = GB/tháng đi qua NAT hoặc Interface VPCE
N = số interface endpoints
```

### 4.1 Current infra design: 1 zonal NAT + S3/DynamoDB Gateway Endpoints

```text
Cost = 1 × 730 × $0.045 + G × $0.045
     = $32.85 + G × $0.045
```

### 4.2 HA NAT: 2 NAT Gateways, mỗi AZ một NAT + S3/DynamoDB Gateway Endpoints

```text
Cost = 2 × 730 × $0.045 + G × $0.045
     = $65.70 + G × $0.045
```

### 4.3 Full VPCE no-NAT: 10 interface endpoints × 2 AZ + S3/DynamoDB Gateway Endpoints

```text
Cost = 10 endpoints × 2 AZ × 730 × $0.010 + G × $0.010
     = $146.00 + G × $0.010
```

Ghi chú: nếu thêm AMP control-plane endpoint (`aps`) ngoài data-plane `aps-workspaces`, số endpoint tăng thành 11 và fixed cost tăng thêm khoảng $14.60/month ở 2 AZ.

## 5. Cost comparison tại `us-east-1`

Pricing dùng trong bảng:

```text
NAT Gateway:       $0.045/hour + $0.045/GB
Interface VPCE:    $0.010/endpoint-AZ-hour + $0.010/GB
Gateway Endpoint:  $0/hour + $0 endpoint processing for S3/DynamoDB
```

### 5.1 Bảng so sánh theo traffic

| Mô hình | Công thức | 0 GB | 12 GB realistic | 100 GB | 500 GB | 3,000 GB |
|---|---:|---:|---:|---:|---:|---:|
| Current: 1 zonal NAT + S3/DDB Gateway EP | `$32.85 + G × $0.045` | **$32.85** | **$33.39** | **$37.35** | **$55.35** | **$167.85** |
| HA NAT: 2 NAT + S3/DDB Gateway EP | `$65.70 + G × $0.045` | **$65.70** | **$66.24** | **$70.20** | **$88.20** | **$200.70** |
| Full VPCE no-NAT: 10 interface EP × 2 AZ + S3/DDB Gateway EP | `$146.00 + G × $0.010` | **$146.00** | **$146.12** | **$147.00** | **$151.00** | **$176.00** |

### 5.2 Break-even

| So sánh | Break-even traffic |
|---|---:|
| Full VPCE no-NAT vs current 1 zonal NAT | `(146.00 - 32.85) / (0.045 - 0.010)` = **~3,233 GB/tháng** |
| Full VPCE no-NAT vs HA 2 NAT | `(146.00 - 65.70) / (0.045 - 0.010)` = **~2,294 GB/tháng** |

Với traffic realistic **~12 GB/tháng**, full VPCE đắt hơn:

```text
Full VPCE vs current zonal NAT: $146.12 - $33.39 = +$112.73/tháng
Full VPCE vs HA NAT:            $146.12 - $66.24 = +$79.88/tháng
```

## 6. Security comparison

| Mô hình | Cost | Security posture | HA egress | Nhận xét |
|---|---:|---|---|---|
| Current 1 zonal NAT + S3/DDB Gateway EP | Thấp nhất | Trung bình-khá | Không HA cho egress | Rẻ nhất cho demo. S3/DDB private, AI internal, nhưng AMP/CloudWatch/SQS/SNS/ECR/Secrets/KMS còn đi outbound qua NAT. |
| HA 2 NAT + S3/DDB Gateway EP | Trung bình | Trung bình-khá | Có HA theo AZ | Tốt hơn zonal NAT về HA nhưng vẫn là outbound NAT path. |
| Full VPCE no-NAT | Cao nhất ở traffic thấp | Tốt nhất | Có HA nếu endpoint đặt ở 2 AZ | Private-only cho AWS APIs, endpoint policy/SG tốt hơn, nhưng fixed cost cao với 10 endpoints. |

Điểm security đã được cải thiện vì AI endpoint là internal endpoint trong VPC. Do đó NAT/VPCE decision chủ yếu ảnh hưởng đến AWS service APIs như AMP, CloudWatch, SQS, SNS, ECR, Secrets Manager và KMS; không ảnh hưởng đến đường gọi AI prediction.

## 7. Decision cho CDO04

### 7.1 Kết luận cost

Với traffic platform gần đúng **~12 GB/tháng**, giải pháp hiện tại **1 zonal NAT Gateway + S3/DynamoDB Gateway Endpoints** là rẻ nhất:

```text
Current zonal NAT: ~ $33.39/month
HA 2 NAT:          ~ $66.24/month
Full VPCE no-NAT:  ~ $146.12/month
```

Full VPCE chỉ bắt đầu có lợi về cost khi traffic AWS API qua private egress vượt khoảng:

```text
~3.2 TB/month so với current zonal NAT
~2.3 TB/month so với HA 2 NAT
```

CDO04 hiện chỉ khoảng **12 GB/month**, thấp hơn break-even rất xa.

### 7.2 Kết luận security

Full VPCE no-NAT là security posture tốt nhất vì:

- Không cần outbound NAT cho AWS service APIs.
- Traffic tới AWS services đi private qua AWS network.
- Có thể dùng endpoint policy để giới hạn service/resource.
- Có security group trên interface endpoint ENI.

Nhưng với 10 interface endpoints × 2 AZ, fixed cost **$146/month** chỉ riêng VPCE là quá cao cho budget capstone khi traffic rất thấp.

### 7.3 Câu chốt để defend

**Chốt: Với scope CDO04 tại `us-east-1`, AI endpoint đã internal và AWS API traffic chỉ khoảng 12GB/tháng, giải pháp tối ưu cost-security cho nền tảng là giữ thiết kế hiện tại: 1 zonal NAT Gateway kết hợp S3 + DynamoDB Gateway Endpoints; full VPCE no-NAT là phương án security-first/production hardening nhưng không tối ưu cost cho capstone vì cần khoảng 10 interface endpoints multi-AZ và chỉ break-even ở mức multi-TB/tháng.**

### 7.4 Production hardening path

Nếu mentor hoặc panel yêu cầu security cao hơn, thứ tự nâng cấp hợp lý:

1. Giữ S3 + DynamoDB Gateway Endpoints như baseline.
2. Thêm interface endpoints theo traffic/security priority:
   - `aps-workspaces` nếu muốn AMP remote_write/query private-only.
   - `logs` và `monitoring` nếu muốn CloudWatch private path.
   - `sqs` và `sns` nếu muốn queue/alert path private.
   - `secretsmanager`, `kms`, `sts` nếu muốn secret/decrypt/SigV4 support private-only.
   - `ecr.api` và `ecr.dkr` nếu muốn image pull no-NAT.
3. Khi đã có đủ endpoints cho toàn bộ runtime path, mới bỏ NAT hoàn toàn.
4. Nếu chỉ cần HA egress nhưng chưa cần private-only, nâng từ 1 zonal NAT lên 2 NAT Gateways, mỗi AZ một NAT.
