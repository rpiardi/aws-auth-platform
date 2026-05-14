# auth-platform

AWS-based M2M authentication platform using Amazon Cognito, API Gateway REST API,
AWS Lambda, and Terraform/OpenTofu.

The public token endpoint is:

```text
POST https://minha-api.freeddns.org/oauth/token
```

## Deploy Locally

```bash
cd terraform
tofu init
tofu plan
tofu apply
```

Equivalent Terraform commands can be used locally if preferred:

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## GitLab CI

The repository uses the GitLab OpenTofu `full-pipeline` component.

The component provides the standard OpenTofu jobs for formatting, validation,
planning, and manual apply. The project sets:

- component version: `4.5.0`
- OpenTofu version: `1.11.5`
- `root_dir`: `terraform`
- `state_name`: `auth-platform-prd`
- destructive cleanup jobs disabled with `destroy_rules` and `delete_state_rules`

Required GitLab CI variables:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION=us-east-1
```

## Retrieve Client Secret

The Cognito App Client secret is not exposed in Terraform outputs. Retrieve it
manually with AWS CLI:

```bash
aws cognito-idp describe-user-pool-client \
  --region us-east-1 \
  --user-pool-id <user_pool_id> \
  --client-id <app_client_id> \
  --query 'UserPoolClient.ClientSecret' \
  --output text
```

## Token Request Format

Use `application/x-www-form-urlencoded`:

```text
grant_type=client_credentials
client_id=<app_client_id>
client_secret=<client_secret>
scope=m2m-prd/read
```

Available scopes:

```text
m2m-prd/read
m2m-prd/write
```

## Generate Token

```bash
curl -X POST "https://minha-api.freeddns.org/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<app_client_id>&client_secret=<client_secret>&scope=m2m-prd/read"
```
