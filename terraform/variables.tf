variable "aws_region" {
  description = "AWS region used by all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource names and tags."
  type        = string
  default     = "auth-platform"
}

variable "stage_name" {
  description = "API Gateway deployment stage name."
  type        = string
  default     = "prd"
}

variable "cognito_domain_prefix" {
  description = "Cognito managed domain prefix."
  type        = string
  default     = "personal-rvpi-auth-platform"
}

variable "resource_server_identifier" {
  description = "Cognito resource server identifier."
  type        = string
  default     = "m2m-prd"
}

variable "access_token_ttl_minutes" {
  description = "Cognito access token TTL in minutes."
  type        = number
  default     = 30
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 5
}

variable "lambda_memory_mb" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days."
  type        = number
  default     = 14
}

variable "custom_domain_name" {
  description = "Existing API Gateway custom domain name."
  type        = string
  default     = "minha-api.freeddns.org"
}

variable "custom_domain_base_path" {
  description = "Base path to map on the existing API Gateway custom domain."
  type        = string
  default     = "oauth"
}
