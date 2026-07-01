# -----------------------------------------------------------------------------
# API Gateway HTTP API -- unified front door for all telemetry + prediction routes
#
# Routes:
#   GET  /health      NONE   -> internal ALB
#   POST /v1/ingest   AWS_IAM -> internal ALB
#   POST /v1/predict  AWS_IAM -> internal ALB
#
# VPC Link integration targets internal ALB HTTP :80 listener.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}-api"
  retention_in_days = var.app_log_retention_days

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-api-access-logs"
    Purpose = "api-access-logs"
  })
}

resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.project_name}-${var.environment}-vpc-link"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [var.vpc_link_sg_id]

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-vpc-link"
    Purpose = "api-gateway-private-integration"
  })
}

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-${var.environment}-api"
  protocol_type = "HTTP"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-api"
    Purpose = "unified-api-front-door"
  })
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.http.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.main.id
  payload_format_version = "1.0"
}

# ── Routes ──

resource "aws_apigatewayv2_route" "health" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /health"
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_route" "ingest" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /v1/ingest"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_route" "predict" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /v1/predict"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

# ── Stage ──

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId         = "$context.requestId"
      ip                = "$context.identity.sourceIp"
      requestTime       = "$context.requestTime"
      httpMethod        = "$context.httpMethod"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      protocol          = "$context.protocol"
      responseLength    = "$context.responseLength"
      integrationStatus = "$context.integrationStatus"
      userArn           = "$context.identity.userArn"
    })
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-api-default-stage"
    Purpose = "api-stage"
  })
}
