terraform {
  backend "s3" {
    bucket       = "rogerio-iac-prod-us-east-1"
    key          = "rogerio.piardi/terraform/auth-platform/prd.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
