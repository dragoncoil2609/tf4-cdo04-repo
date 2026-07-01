moved {
  from = aws_cloudwatch_log_group.ai_api_access
  to   = aws_cloudwatch_log_group.api_access
}

moved {
  from = aws_apigatewayv2_vpc_link.ai_engine
  to   = aws_apigatewayv2_vpc_link.main
}

moved {
  from = aws_apigatewayv2_api.ai_engine
  to   = aws_apigatewayv2_api.main
}

moved {
  from = aws_apigatewayv2_integration.ai_engine
  to   = aws_apigatewayv2_integration.alb
}

moved {
  from = aws_apigatewayv2_route.ai_health
  to   = aws_apigatewayv2_route.health
}

moved {
  from = aws_apigatewayv2_route.ai_predict
  to   = aws_apigatewayv2_route.predict
}

moved {
  from = aws_lb.public
  to   = aws_lb.main
}
