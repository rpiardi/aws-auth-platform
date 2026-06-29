resource "aws_cloudwatch_log_group" "lambda_wrapper" {
  name              = "/aws/lambda/${var.project_name}-lambda-wrapper"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api_gateway_access_logs" {
  name              = "/aws/apigateway/${var.project_name}-access-logs"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "pretoken" {
  name              = "/aws/lambda/${var.project_name}-lambda-pretoken"
  retention_in_days = var.log_retention_days
}
