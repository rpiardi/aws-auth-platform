data "archive_file" "lambda_wrapper" {
  type        = "zip"
  source_file = "${path.module}/../src/wrapper/lambda_function.py"
  output_path = "${path.module}/lambda_wrapper.zip"
}

resource "aws_lambda_function" "wrapper" {
  function_name = "${var.project_name}-lambda-wrapper"
  role          = aws_iam_role.lambda_wrapper.arn

  runtime     = "python3.12"
  handler     = "lambda_function.lambda_handler"
  filename    = data.archive_file.lambda_wrapper.output_path
  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  source_code_hash = data.archive_file.lambda_wrapper.output_base64sha256

  environment {
    variables = {
      COGNITO_TOKEN_URL = local.cognito_token_url
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_wrapper,
    aws_iam_role_policy.lambda_logs,
  ]
}
