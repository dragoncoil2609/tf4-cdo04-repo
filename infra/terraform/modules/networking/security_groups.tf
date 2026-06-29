# -----------------------------------------------------------------------------
# Security Groups -- CDO-W12-004
#
# Security boundary:
# - Public ALB exposes HTTP (port 80) ingress for current scope.
#   HTTPS/ACM is deferred to team assignment; do NOT add HTTPS here.
# - Telemetry API only accepts traffic from ALB.
# - Prediction Worker has no public inbound.
# - AI Engine only accepts private traffic from Worker/Service Connect path.
# -----------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public ALB security group for /v1/ingest (HTTP)"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name    = "${var.project_name}-alb-sg"
    Purpose = "public-ingest-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_from_public" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from public/demo clients"

  cidr_ipv4   = var.alb_ingress_cidr
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_telemetry_api" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow ALB to forward traffic to Telemetry API"

  referenced_security_group_id = aws_security_group.telemetry_api.id
  from_port                    = var.app_port
  ip_protocol                  = "tcp"
  to_port                      = var.app_port
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
  description       = "Allow Prediction Worker to call AI Engine"

  referenced_security_group_id = aws_security_group.prediction_worker.id
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