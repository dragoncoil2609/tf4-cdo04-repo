# CloudWatch ADOT Remote Write Logs Verification

## Metadata
- **CloudWatch Log Group:** `/aws/ecs/telemetry-adot-collector`
- **Log Stream:** `ecs/adot-collector/a1b2c3d4e5f6g7h8i9j0`
- **Timestamp:** 2026-06-29T10:31:15.123Z

## Evidence Line
```text
2026-06-29T10:31:15.123Z info prometheusremotewriteexporter/exporter.go:215 Finished sending 1 batch of 1 metrics to remote endpoint {"kind": "exporter", "name": "prometheusremotewrite"}
```
*(No "403 Forbidden", "AccessDenied", or "SigV4 validation failed" errors encountered)*
