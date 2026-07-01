# -----------------------------------------------------------------------------
# API Gateway HTTP API for AI Engine SigV4 enforcement
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ai_api_access" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}-ai-api"
  retention_in_days = var.app_log_retention_days

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-api-access-logs"
    Purpose = "ai-api-access-logs"
  })
}

resource "aws_apigatewayv2_vpc_link" "ai_engine" {
  name               = "${var.project_name}-${var.environment}-ai-vpc-link"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [var.vpc_link_sg_id]

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-vpc-link"
    Purpose = "api-gateway-ai-private-integration"
  })
}

resource "aws_apigatewayv2_api" "ai_engine" {
  name          = "${var.project_name}-${var.environment}-ai-api"
  protocol_type = "HTTP"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-api"
    Purpose = "ai-sigv4-front-door"
  })
}

resource "aws_apigatewayv2_integration" "ai_engine" {
  api_id                 = aws_apigatewayv2_api.ai_engine.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.ai_restricted_https.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.ai_engine.id
  payload_format_version = "1.0"

  tls_config {
    server_name_to_verify = var.domain_name
  }
}

resource "aws_apigatewayv2_route" "ai_predict" {
  api_id             = aws_apigatewayv2_api.ai_engine.id
  route_key          = "POST /v1/predict"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.ai_engine.id}"
}

resource "aws_apigatewayv2_route" "ai_health" {
  api_id             = aws_apigatewayv2_api.ai_engine.id
  route_key          = "GET /health"
  authorization_type = "AWS_IAM"
  target             = "integrations/${aws_apigatewayv2_integration.ai_engine.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.ai_engine.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.ai_api_access.arn
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
    Name    = "${var.project_name}-${var.environment}-ai-api-default-stage"
    Purpose = "ai-api-stage"
  })
}
