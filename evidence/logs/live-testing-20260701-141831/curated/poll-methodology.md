# Poll Methodology

Accepted live-test polling used one-shot polling, not a long shell sleep loop.

Each poll captured:

```text
k6 tail/status
ECS service desired/running/pending/deployment counts
SQS main queue visible/inflight counts
SQS DLQ visible/inflight counts
AMP instant queries for 3 services x 7 metrics
DynamoDB latest audit rows for tenant demo-tenant-001
```

Rejected approach:

```text
long shell sleep loop for 25-minute polling
```

The source run folder keeps the original script as historical diagnostic context. Curated evidence keeps methodology only, no credential-loading script.
