output "user_pool_id" {
  description = "Cognito User Pool ID."
  value       = aws_cognito_user_pool.m2m.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN."
  value       = aws_cognito_user_pool.m2m.arn
}

output "app_client_id" {
  description = "Cognito App Client ID."
  value       = aws_cognito_user_pool_client.m2m.id
}

output "cognito_token_url" {
  description = "Cognito OAuth2 token endpoint."
  value       = local.cognito_token_url
}

output "auth_api_id" {
  description = "API Gateway REST API ID."
  value       = aws_api_gateway_rest_api.auth.id
}

output "auth_api_invoke_url" {
  description = "API Gateway stage invoke URL."
  value       = aws_api_gateway_stage.prd.invoke_url
}

output "auth_api_custom_domain_url" {
  description = "Custom domain token URL."
  value       = "https://${var.custom_domain_name}/${var.custom_domain_base_path}/token"
}
