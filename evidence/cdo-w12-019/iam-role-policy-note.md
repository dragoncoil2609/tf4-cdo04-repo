# IAM Role and Policy Verification Note

## Details
- **Task Role ARN:** `arn:aws:iam::<ACCOUNT_ID>:role/telemetry-api-task-role`
- **Attached Policy Name:** `TelemetryApiAmpRemoteWritePolicy`
- **Permission Allowed:** `aps:RemoteWrite`
- **Long-lived Token Used:** **No** (Uses AWS ECS Task Role IAM Credentials dynamically signed with SigV4)
