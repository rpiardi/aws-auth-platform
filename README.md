# auth-platform

AWS-based M2M authentication platform using Amazon Cognito, API Gateway REST API,
AWS Lambda, and Terraform/OpenTofu.

Detailed implementation notes, CI behavior, AWS permissions, and troubleshooting
are documented in [docs/implementation.md](docs/implementation.md).

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

## GitHub Actions

GitHub is the primary repository and GitHub Actions is the active CI/CD system.

Pull requests run:

```text
OpenTofu Format
OpenTofu Validate
```

Both checks are required by the protected `main` branch.

Deployments use the manual `OpenTofu Deployment` workflow. Select `plan` to
preview changes or `apply` to create and apply a saved plan in the same job.
The workflow uses OpenTofu `1.11.5`, the `prd` environment, and the existing S3
state backend.

AWS authentication uses GitHub OIDC with:

```text
AWS_ROLE_ARN=arn:aws:iam::209479281611:role/AuthPlatformGitHubDeployer
```

`AWS_ROLE_ARN` is an environment variable in `prd`. No long-lived AWS access
keys are stored in GitHub.

The former GitLab pipeline is archived at
[`docs/archive/gitlab-ci.yml`](docs/archive/gitlab-ci.yml) and must not be used
for deployments.

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
