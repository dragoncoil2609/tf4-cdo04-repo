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

## ADR-002 - To be added

- **Status**: Proposed
- **Date**: 2026-MM-DD
- **Context**: To be filled.
- **Decision**: To be filled.
- **Consequence**:
  - ✅ To be filled.
  - ⚠️ To be filled.
- **Alternatives considered**:
  - To be filled.

---

## ADR-003 - To be added

- **Status**: Proposed
- **Date**: 2026-MM-DD
- **Context**: To be filled.
- **Decision**: To be filled.
- **Consequence**:
  - ✅ To be filled.
  - ⚠️ To be filled.
- **Alternatives considered**:
  - To be filled.

---

## Related documents

- `docs/00_client_debrief.md` - client discovery summary and scope lock
- `docs/01_requirements_analysis.md` - requirements, constraints and open questions
- `docs/02_infra_design.md` - infrastructure design and component architecture
- `docs/03_security_design.md` - IAM, secrets, encryption and audit controls
- `docs/04_deployment_design.md` - CI/CD, rollback and deployment workflow