# -----------------------------------------------------------------------------
# Public Application Load Balancer -- CDO-W12-055
#
# Exposes /health and /v1/ingest through HTTP or HTTPS depending on enable_https.
# When HTTPS is enabled, port 80 redirects to 443 using the ACM certificate below.
# /metrics is intentionally not routed; ADOT scrapes it on localhost inside the task.
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
    type = var.enable_https ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = var.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = var.enable_https ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "Not Found"
        status_code  = "404"
      }
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-http-listener"
    Purpose = var.enable_https ? "http-to-https-redirect-listener" : "http-ingest-listener"
  })
}

resource "aws_lb_listener" "https" {
  count             = var.enable_https ? 1 : 0
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
  listener_arn = var.enable_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
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

resource "aws_lb_listener" "ai_restricted_https" {
  load_balancer_arn = aws_lb.public.arn
  port              = var.ai_listener_port
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
    Name    = "${var.project_name}-${var.environment}-ai-restricted-https-listener"
    Purpose = "api-gateway-ai-listener"
  })
}

resource "aws_lb_listener_rule" "ai_predict" {
  listener_arn = aws_lb_listener.ai_restricted_https.arn
  priority     = 10

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

resource "aws_lb_listener_rule" "ai_health" {
  listener_arn = aws_lb_listener.ai_restricted_https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai_engine.arn
  }

  condition {
    path_pattern {
      values = ["/health"]
    }
  }

  tags = merge(var.tags, {
    Purpose = "ai-health-rule"
  })
}
