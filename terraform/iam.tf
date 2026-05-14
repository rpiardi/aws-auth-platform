data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${aws_cloudwatch_log_group.lambda_wrapper.arn}:*",
    ]
  }
}

resource "aws_iam_role" "lambda_wrapper" {
  name               = "${var.project_name}-lambda-wrapper-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "lambda_logs" {
  name   = "${var.project_name}-lambda-wrapper-logs"
  role   = aws_iam_role.lambda_wrapper.id
  policy = data.aws_iam_policy_document.lambda_logs.json
}
