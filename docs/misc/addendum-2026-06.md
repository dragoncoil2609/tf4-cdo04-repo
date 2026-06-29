# Contract Addendum — June 2026 Drift Notes

Status: implementation sync note, not a replacement for frozen contracts.

Frozen contract files signed on 2026-06-25 remain unchanged. This addendum documents implementation drift for MVP review.

## Endpoint path

Public ingest endpoint for current implementation:

```text
POST /v1/ingest
```

`src/telemetry_api/app.py` contains legacy standalone `/v1/telemetry` code. Production app wiring uses `src/telemetry_api/main.py` and `/v1/ingest`.

## Service ID mapping

Implementation canonical IDs:

| Frozen / early docs name | Current canonical ID |
|---|---|
| `payment-gateway` | `payment-gw` |
| `ledger-service` | `ledger` |
| `kyc-worker` | `fraud-detector` |
| `fraud-detection` | `fraud-detector` |

Canonical IDs are used by AI baselines, Terraform `prediction_services`, and k6 scenarios.

## Metrics backend

Amazon Timestream references are historical. Current MVP backend is Amazon Managed Service for Prometheus (AMP), with ADOT/remote-write path documented in ADR-011 and roadmap notes.

## Deployment strategy

CodeDeploy/canary references are historical or post-MVP. Current MVP deploy strategy is ECS rolling deployment with ECS deployment circuit breaker and rollback.

## Out-of-scope fallback table

Tuấn-owned fallback policy table work remains out of scope for this batch. Prediction worker degraded fallback behavior must not block Batch 6–8 validation.
