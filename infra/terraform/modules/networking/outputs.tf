# ----------------------------------------------------------------------------
# CDO-04 Networking Module -- Outputs
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = aws_nat_gateway.main.id
}

output "s3_endpoint_id" {
  description = "VPC Gateway Endpoint ID for S3"
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_endpoint_id" {
  description = "VPC Gateway Endpoint ID for DynamoDB"
  value       = aws_vpc_endpoint.dynamodb.id
}

# TODO (CPOA-40): Security group outputs belong to Security Groups owner.
output "alb_sg_id" {
  description = "Security group ID for the internal ALB"
  value       = aws_security_group.alb.id
}

output "telemetry_api_sg_id" {
  description = "Security group ID for the Telemetry API ECS service"
  value       = aws_security_group.telemetry_api.id
}

output "prediction_worker_sg_id" {
  description = "Security group ID for the Prediction Worker ECS service"
  value       = aws_security_group.prediction_worker.id
}

output "ai_engine_sg_id" {
  description = "Security group ID for the AI Engine ECS service"
  value       = aws_security_group.ai_engine.id
}

output "vpc_link_sg_id" {
  description = "Security group ID for API Gateway VPC Link ENIs"
  value       = aws_security_group.vpc_link.id
}