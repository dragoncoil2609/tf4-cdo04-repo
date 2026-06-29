# -----------------------------------------------------------------------------
# TASK: CPOA-99 | CDO-W12-054 - AWS Budget 50/80/100 Cost Circuit Breaker
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# This Lambda function acts as a Cost Circuit Breaker. When AWS Budgets sends a 
# cost threshold breach notification to the budget alert SNS Topic:
# 1. It parses the JSON message to identify the actual threshold value breached.
# 2. If it is the 100% threshold ($200 budget ceiling), it triggers a scale-down action.
# 3. It updates the ECS services 'ai-engine' and 'prediction-worker' to desiredCount=0.
#    This cuts compute costs of non-essential billing components, keeping 'telemetry-api'
#    alive so we do not lose metric ingestion.
# 4. It notifies the operations team by publishing a critical alert email back to the SNS Topic.
# -----------------------------------------------------------------------------

import os
import json
import boto3
import logging

# Configure logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    logger.info("Received event: %s", json.dumps(event))
    
    cluster_name = os.environ.get("CLUSTER_NAME")
    ai_service = os.environ.get("SERVICE_NAME")
    worker_service = os.environ.get("WORKER_SERVICE_NAME")
    sns_topic_arn = os.environ.get("SNS_TOPIC_ARN")
    
    logger.info("Configured variables - Cluster: %s, AI Service: %s, Worker Service: %s, SNS Topic: %s", 
                cluster_name, ai_service, worker_service, sns_topic_arn)
                
    # Parse SNS message to verify if this is indeed the 100% threshold breach
    should_activate = False
    for record in event.get("Records", []):
        sns_record = record.get("Sns", {})
        message_str = sns_record.get("Message", "")
        
        logger.info("Parsing SNS Message: %s", message_str)
        try:
            # Budgets payload is JSON format
            message_json = json.loads(message_str)
            threshold_info = message_json.get("thresholdInfo", {})
            threshold_val = threshold_info.get("thresholdValue")
            if threshold_val is None:
                # Try the flat structure key
                threshold_val = message_json.get("Threshold")
                
            logger.info("Extracted threshold value: %s", threshold_val)
            if threshold_val is not None:
                val_float = float(threshold_val)
                # Activate only on 100% or greater actual cost breach
                if val_float >= 100.0:
                    should_activate = True
        except Exception as e:
            logger.warning("Could not parse SNS message as JSON: %s. Performing string search fallback.", str(e))
            # Fallback string matching to be safe
            if "100%" in message_str or "100.0" in message_str or "thresholdInfo" in message_str:
                should_activate = True
                
    if not should_activate:
        logger.info("Notification is not for 100% threshold breach. Skipping scale-down action.")
        return {
            "statusCode": 200,
            "body": json.dumps("Skipped scale-down (not 100% threshold)")
        }
    
    ecs = boto3.client("ecs")
    sns = boto3.client("sns")
    
    # Scale down services to 0 (both ai-engine and prediction-worker)
    services_to_stop = [
        ("AI Engine", ai_service),
        ("Prediction Worker", worker_service)
    ]
    
    scale_down_results = []
    
    for label, service_name in services_to_stop:
        if not service_name:
            logger.warning("No service name configured for %s", label)
            continue
            
        try:
            logger.info("Attempting to scale down %s (%s) to 0...", label, service_name)
            response = ecs.update_service(
                cluster=cluster_name,
                service=service_name,
                desiredCount=0
            )
            logger.info("Successfully scaled down %s. Response: %s", label, json.dumps(response, default=str))
            scale_down_results.append(f"- {label} ({service_name}): Scaled down to 0 successfully.")
        except Exception as e:
            logger.error("Failed to scale down %s (%s): %s", label, service_name, str(e))
            scale_down_results.append(f"- {label} ({service_name}): Failed to scale down due to: {str(e)}")
            
    # Send email notification via SNS
    subject = "CRITICAL: CDO Platform Cost Limit Reached - Circuit Breaker Activated"
    sns_message = "AWS Budget alarm triggered the Circuit Breaker.\n\n"
    sns_message += "Budget Limit: $200.00 (100% threshold exceeded)\n"
    sns_message += f"ECS Cluster: {cluster_name}\n"
    sns_message += "Actions taken:\n"
    for result in scale_down_results:
        sns_message += result + "\n"
        
    try:
        logger.info("Sending alert email via SNS...")
        sns.publish(
            TopicArn=sns_topic_arn,
            Subject=subject,
            Message=sns_message
        )
        logger.info("Notification email sent successfully.")
    except Exception as e:
        logger.error("Failed to send SNS notification: %s", str(e))
        
    return {
        "statusCode": 200,
        "body": json.dumps("Cost Circuit Breaker executed successfully")
    }
