"""Lambda function to calculate the age of the oldest object in the S3 failure buffer

and publish it as a custom CloudWatch metric.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
import boto3

s3_client = boto3.client("s3")
cw_client = boto3.client("cloudwatch")


def lambda_handler(event, context):
    """Scan S3 failure buffer bucket, calculate oldest object age, and publish to CloudWatch."""

    bucket_name = os.environ.get("S3_FAILURE_BUFFER_BUCKET", "cdo-telemetry-failure-buffer")
    prefix = os.environ.get("S3_FAILURE_BUFFER_PREFIX", "telemetry-failures/")
    namespace = os.environ.get("CLOUDWATCH_NAMESPACE", "CDO/TelemetryApi")
    metric_name = "FailureBufferOldestObjectAgeSeconds"

    print(f"Scanning bucket s3://{bucket_name}/{prefix} for oldest object...")

    try:
        paginator = s3_client.get_paginator("list_objects_v2")
        pages = paginator.paginate(Bucket=bucket_name, Prefix=prefix)

        oldest_time = None
        object_count = 0

        for page in pages:
            if "Contents" not in page:
                continue

            for obj in page["Contents"]:
                key = obj["Key"]
                # Only analyze JSON buffer objects
                if not key.endswith(".json"):
                    continue

                object_count += 1
                last_modified = obj["LastModified"]  # datetime with UTC timezone
                if oldest_time is None or last_modified < oldest_time:
                    oldest_time = last_modified

        age_seconds = 0.0
        if oldest_time is not None:
            now = datetime.now(timezone.utc)
            age_seconds = (now - oldest_time).total_seconds()
            print(f"Found {object_count} objects. Oldest modified at: {oldest_time}. Age: {age_seconds:.2f} seconds.")
        else:
            print("No failure objects found in the buffer. Age is 0 seconds.")

        # Publish the metric to CloudWatch
        cw_client.put_metric_data(
            Namespace=namespace,
            MetricData=[
                {
                    "MetricName": metric_name,
                    "Dimensions": [
                        {"Name": "BucketName", "Value": bucket_name},
                    ],
                    "Timestamp": datetime.now(timezone.utc),
                    "Value": age_seconds,
                    "Unit": "Seconds",
                }
            ],
        )
        print(f"Successfully published metric {metric_name} with value {age_seconds} to namespace {namespace}.")

        return {
            "statusCode": 200,
            "body": {
                "object_count": object_count,
                "oldest_object_age_seconds": age_seconds,
                "metric_published": True,
            },
        }

    except Exception as exc:
        print(f"Error checking failure buffer age: {exc}")
        raise exc
