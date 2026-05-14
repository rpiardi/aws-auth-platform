locals {
  cognito_token_url = "https://${var.cognito_domain_prefix}.auth.${var.aws_region}.amazoncognito.com/oauth2/token"
}

resource "aws_cognito_user_pool" "m2m" {
  name = "${var.project_name}-m2m-user-pool"
}

resource "aws_cognito_resource_server" "m2m" {
  identifier = var.resource_server_identifier
  name       = "${var.project_name}-resource-server"

  user_pool_id = aws_cognito_user_pool.m2m.id

  scope {
    scope_name        = "read"
    scope_description = "Read access"
  }

  scope {
    scope_name        = "write"
    scope_description = "Write access"
  }
}

resource "aws_cognito_user_pool_client" "m2m" {
  name = "${var.project_name}-m2m-client"

  user_pool_id = aws_cognito_user_pool.m2m.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${var.resource_server_identifier}/read",
    "${var.resource_server_identifier}/write",
  ]

  access_token_validity = var.access_token_ttl_minutes

  token_validity_units {
    access_token = "minutes"
  }

  depends_on = [
    aws_cognito_resource_server.m2m,
  ]
}

resource "aws_cognito_user_pool_domain" "m2m" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.m2m.id
}
