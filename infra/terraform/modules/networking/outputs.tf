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

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "ecs_api_security_group_id" {
  description = "ECS API (Telemetry) security group ID"
  value       = aws_security_group.ecs_api.id
}

output "worker_security_group_id" {
  description = "Worker security group ID"
  value       = aws_security_group.worker.id
}

output "ai_engine_security_group_id" {
  description = "AI Engine security group ID"
  value       = aws_security_group.ai_engine.id
}
