"""CDO-04 mock E2E app.

One image runs three roles through MOCK_ROLE:
- api: POST /v1/ingest -> SQS
- worker: SQS -> AI -> DynamoDB + S3 -> delete message
- ai: POST /v1/predict -> fake prediction

This is intentionally small, but mirrors production boundaries: HTTP ingress,
queue handoff, service-to-service call, audit write, evidence write.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import boto3
import requests

ROLE = os.environ.get("MOCK_ROLE", "api")
PORT = int(os.environ.get("PORT", "8080"))


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", 0))
    body = handler.rfile.read(length).decode("utf-8") if length else "{}"
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {"raw": body}
    return parsed if isinstance(parsed, dict) else {"value": parsed}


def send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def serve(handler: type[BaseHTTPRequestHandler], role: str) -> None:
    print(f"[{role}] starting on port {PORT}", file=sys.stderr, flush=True)
    HTTPServer(("0.0.0.0", PORT), handler).serve_forever()


def run_api() -> None:
    queue_url = os.environ["PREDICTION_QUEUE_URL"]
    sqs = boto3.client("sqs")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/health":
                send_json(self, 200, {"status": "ok", "role": "api"})
                return
            send_json(self, 404, {"error": "not_found"})

        def do_POST(self) -> None:
            if self.path != "/v1/ingest":
                send_json(self, 404, {"error": "not_found"})
                return

            message = {
                "id": str(uuid.uuid4()),
                "timestamp": now_iso(),
                "payload": read_json(self),
            }
            sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message))
            send_json(self, 202, {"status": "accepted", "id": message["id"]})

        def log_message(self, fmt: str, *args: Any) -> None:
            print(f"[api] {fmt % args}", file=sys.stderr, flush=True)

    serve(Handler, "api")


def run_ai() -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/health":
                send_json(self, 200, {"status": "ok", "role": "ai"})
                return
            send_json(self, 404, {"error": "not_found"})

        def do_POST(self) -> None:
            if self.path != "/v1/predict":
                send_json(self, 404, {"error": "not_found"})
                return

            send_json(
                self,
                200,
                {
                    "prediction_id": str(uuid.uuid4()),
                    "risk_score": 0.42,
                    "risk_level": "medium",
                    "flags": ["mock_flag_1", "mock_flag_2"],
                    "input_summary": str(read_json(self))[:200],
                    "model_version": "mock-v0.1.0",
                    "timestamp": now_iso(),
                },
            )

        def log_message(self, fmt: str, *args: Any) -> None:
            print(f"[ai] {fmt % args}", file=sys.stderr, flush=True)

    serve(Handler, "ai")


def audit_item(message: dict[str, Any], prediction: dict[str, Any]) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    payload = message.get("payload", {}) if isinstance(message.get("payload"), dict) else {}
    return {
        "tenant_id": str(payload.get("tenant_id", "mock-tenant")),
        "service_time": now.isoformat(),
        "prediction_status": "complete" if "error" not in prediction else "failed",
        "prediction_timestamp": now.isoformat(),
        "expires_at_epoch": int(now.timestamp()) + 86400,
        "prediction_id": prediction.get("prediction_id", message.get("id", str(uuid.uuid4()))),
        "ingest_id": message.get("id", str(uuid.uuid4())),
        "risk_score": str(prediction.get("risk_score", -1)),
        "risk_level": prediction.get("risk_level", "unknown"),
        "raw_prediction": json.dumps(prediction),
    }


def run_worker() -> None:
    queue_url = os.environ["PREDICTION_QUEUE_URL"]
    ai_url = os.environ["AI_ENGINE_URL"].rstrip("/")
    table = boto3.resource("dynamodb").Table(os.environ["AUDIT_TABLE_NAME"])
    bucket = os.environ["EVIDENCE_BUCKET_NAME"]
    sqs = boto3.client("sqs")
    s3 = boto3.client("s3")

    print(f"[worker] polling {queue_url}, ai={ai_url}", file=sys.stderr, flush=True)
    while True:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for sqs_message in response.get("Messages", []):
            receipt_handle = sqs_message["ReceiptHandle"]
            message = json.loads(sqs_message["Body"])
            ingest_id = message.get("id", str(uuid.uuid4()))
            print(f"[worker] processing {ingest_id}", file=sys.stderr, flush=True)

            try:
                ai_response = requests.post(
                    f"{ai_url}/v1/predict",
                    json={"ingest_id": ingest_id, "payload": message.get("payload", {})},
                    timeout=30,
                )
                ai_response.raise_for_status()
                prediction = ai_response.json()
            except Exception as exc:  # smoke app records failure then deletes to avoid poison loop
                prediction = {"error": str(exc), "risk_score": -1}

            item = audit_item(message, prediction)
            table.put_item(Item=item)
            print("[worker] wrote DynamoDB", file=sys.stderr, flush=True)

            key = f"smoke/{item['prediction_id']}.json"
            s3.put_object(Bucket=bucket, Key=key, Body=json.dumps(item), ContentType="application/json")
            print(f"[worker] wrote s3://{bucket}/{key}", file=sys.stderr, flush=True)

            sqs.delete_message(QueueUrl=queue_url, ReceiptHandle=receipt_handle)
            print(f"[worker] deleted {ingest_id}", file=sys.stderr, flush=True)

        if "Messages" not in response:
            print("[worker] no messages", file=sys.stderr, flush=True)


def main() -> None:
    if ROLE == "api":
        run_api()
    elif ROLE == "ai":
        run_ai()
    elif ROLE == "worker":
        run_worker()
    else:
        raise SystemExit(f"Unknown MOCK_ROLE={ROLE}. Use api, worker, or ai.")


if __name__ == "__main__":
    main()
