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

# --- Pre Token Generation trigger ---

data "aws_iam_policy_document" "pretoken_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${aws_cloudwatch_log_group.pretoken.arn}:*",
    ]
  }
}

# Deliberate exception to the auth-platform "no DynamoDB" charter: the trigger
# owns partner identity, which belongs to the auth domain. Scoped to GetItem on
# the auth-partners table only. See AGENTS.md.
data "aws_iam_policy_document" "pretoken_partners" {
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.auth_partners.arn]
  }
}

resource "aws_iam_role" "pretoken" {
  name               = "${var.project_name}-lambda-pretoken-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "pretoken_logs" {
  name   = "${var.project_name}-lambda-pretoken-logs"
  role   = aws_iam_role.pretoken.id
  policy = data.aws_iam_policy_document.pretoken_logs.json
}

resource "aws_iam_role_policy" "pretoken_partners" {
  name   = "${var.project_name}-lambda-pretoken-partners"
  role   = aws_iam_role.pretoken.id
  policy = data.aws_iam_policy_document.pretoken_partners.json
}
