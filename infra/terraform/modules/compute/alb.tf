# -----------------------------------------------------------------------------
# Public HTTP Application Load Balancer -- CDO-W12-055
#
# Exposes /health and /v1/ingest on port 80 only (no HTTPS/ACM).
# /metrics is intentionally not routed; ADOT scrapes it on localhost inside the task.
# HTTPS and certificate wiring are deferred to team assignment scope.
# -----------------------------------------------------------------------------

resource "aws_lb" "public" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-alb"
    Purpose = "public-ingest-alb"
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

resource "aws_acm_certificate" "cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-acm-cert"
    Purpose = "alb-https-cert"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-http-listener"
    Purpose = "http-to-https-redirect-listener"
  })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-https-listener"
    Purpose = "https-ingest-listener"
  })
}

resource "aws_lb_listener_rule" "ingest" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.telemetry_api.arn
  }

  condition {
    path_pattern {
      values = ["/health", "/v1/ingest"]
    }
  }

  tags = merge(var.tags, {
    Purpose = "telemetry-ingest-rule"
  })
}
