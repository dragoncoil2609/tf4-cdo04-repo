# -----------------------------------------------------------------------------
# Security Groups -- CDO-W12-004 (migrated to internal ALB + API Gateway)
#
# Security boundary:
# - ALB is internal. Only accepts traffic from API Gateway VPC Link on port 80.
# - No public ingress on ALB (API Gateway is the front door).
# - Telemetry API only accepts traffic from ALB.
# - Prediction Worker has no public inbound.
# - AI Engine only accepts private traffic from ALB and Worker.
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Internal ALB security group reachable via API Gateway VPC Link"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-alb-sg"
    Purpose = "internal-alb"
  })
}

# Only ingress to ALB: VPC Link ENIs on HTTP port 80.
resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow API Gateway VPC Link to reach internal ALB HTTP listener"

  referenced_security_group_id = aws_security_group.vpc_link.id
  from_port                    = 80
  ip_protocol                  = "tcp"
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_telemetry_api" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow ALB to forward traffic to Telemetry API"

  referenced_security_group_id = aws_security_group.telemetry_api.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ai_engine" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow ALB to forward traffic to AI Engine"

  referenced_security_group_id = aws_security_group.ai_engine.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-vpc-link-sg"
  description = "API Gateway VPC Link security group for private integration"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-vpc-link-sg"
    Purpose = "api-gateway-vpc-link"
  })
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Allow VPC Link ENIs to reach internal ALB HTTP listener"

  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  ip_protocol                  = "tcp"
  to_port                      = 80
}

resource "aws_security_group" "telemetry_api" {
  name        = "${var.project_name}-telemetry-api-sg"
  description = "Telemetry API ECS task security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-telemetry-api-sg"
    Purpose = "telemetry-ingestion-api"
  })
}

resource "aws_vpc_security_group_ingress_rule" "telemetry_api_from_alb" {
  security_group_id = aws_security_group.telemetry_api.id
  description       = "Allow ALB to reach Telemetry API"

  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "telemetry_api_all_egress" {
  security_group_id = aws_security_group.telemetry_api.id
  description       = "Allow Telemetry API outbound to AWS services via NAT/VPC endpoints"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_security_group" "prediction_worker" {
  name        = "${var.project_name}-prediction-worker-sg"
  description = "Prediction Worker ECS task security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-prediction-worker-sg"
    Purpose = "prediction-worker"
  })
}

resource "aws_vpc_security_group_egress_rule" "worker_to_ai_engine" {
  security_group_id = aws_security_group.prediction_worker.id
  description       = "Allow Worker to call AI Engine through private service path"

  referenced_security_group_id = aws_security_group.ai_engine.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "worker_all_egress" {
  security_group_id = aws_security_group.prediction_worker.id
  description       = "Allow Worker outbound to AWS services via NAT/VPC endpoints"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_security_group" "ai_engine" {
  name        = "${var.project_name}-ai-engine-sg"
  description = "AI Engine ECS task security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-ai-engine-sg"
    Purpose = "ai-engine"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ai_engine_from_worker" {
  security_group_id = aws_security_group.ai_engine.id
  description       = "Allow Prediction Worker to call AI Engine during Service Connect fallback"

  referenced_security_group_id = aws_security_group.prediction_worker.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_ingress_rule" "ai_engine_from_alb" {
  security_group_id = aws_security_group.ai_engine.id
  description       = "Allow internal ALB to reach AI Engine"

  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "ai_engine_all_egress" {
  security_group_id = aws_security_group.ai_engine.id
  description       = "Allow AI Engine outbound to S3/CloudWatch/AWS services via NAT/VPC endpoints"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
