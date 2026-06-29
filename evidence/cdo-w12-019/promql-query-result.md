# PromQL Query Verification Result

## PromQL Query
```promql
api_latency_ms{tenant_id="demo-tenant-001",service_id="payment-gateway"}
```

## Result
```text
api_latency_ms{env="production",region="us-east-1",service_id="payment-gateway",service_tier="gold",tenant_id="demo-tenant-001"} 450.5
```

## Details
- **Timestamp:** 2026-06-29T10:30:00Z
- **AWS Region:** us-east-1
- **AMP Workspace ID:** `ws-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
