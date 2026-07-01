# -----------------------------------------------------------------------------
# Internal Application Load Balancer -- CDO-W12-055 (migrated to API Gateway front)
#
# ALB is internal in private subnets, reachable only via API Gateway VPC Link.
# Single HTTP :80 listener routes to Telemetry API and AI Engine target groups.
# ACM certificate retained for API Gateway custom domain, not attached to ALB.
# -----------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.private_subnet_ids

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-alb"
    Purpose = "internal-api-alb"
  })
}

resource "aws_lb_target_group" "telemetry_api" {
  name                 = "${var.project_name}-${var.environment}-telemetry-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-telemetry-tg"
    Purpose = "telemetry-api-target-group"
  })
}

resource "aws_lb_target_group" "ai_engine" {
  name                 = "${var.project_name}-${var.environment}-ai-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-tg"
    Purpose = "ai-engine-target-group"
  })
}

# ACM certificate retained for future API Gateway custom domain integration.
# ponytail: custom domain is deferred; upgrade by adding
# aws_apigatewayv2_domain_name + api_mapping after Name.com CNAME is ready.
resource "aws_acm_certificate" "cert" {
  count = var.enable_acm ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-acm-cert"
    Purpose = "api-gateway-custom-domain-cert"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Single HTTP listener on :80 -- all traffic arrives via API Gateway VPC Link.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-http-listener"
    Purpose = "internal-alb-http-listener"
  })
}

# Path-based routing rules on the single HTTP listener.
resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.telemetry_api.arn
  }

  condition {
    path_pattern {
      values = ["/health"]
    }
  }

  tags = merge(var.tags, {
    Purpose = "health-rule"
  })
}

resource "aws_lb_listener_rule" "ingest" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.telemetry_api.arn
  }

  condition {
    path_pattern {
      values = ["/v1/ingest"]
    }
  }

  tags = merge(var.tags, {
    Purpose = "telemetry-ingest-rule"
  })
}

resource "aws_lb_listener_rule" "predict" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_engine.arn
  }

  condition {
    path_pattern {
      values = ["/v1/predict"]
    }
  }

  tags = merge(var.tags, {
    Purpose = "ai-predict-rule"
  })
}
