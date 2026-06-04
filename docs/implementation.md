# auth-platform implementation notes

This document records what was implemented, how the GitLab pipeline works, and
the operational details needed to deploy and troubleshoot the project.

## Scope

This repository implements only the authentication platform. It does not contain
business APIs.

The platform provides an OAuth2 M2M token endpoint backed by:

- Amazon Cognito
- API Gateway REST API
- Lambda wrapper
- OpenTofu/Terraform
- GitLab CI

Request flow:

```text
Consumer
   -> client_id + client_secret + scope
API Gateway REST API
   -> Lambda wrapper
Cognito /oauth2/token
   -> JWT access token
```

The Lambda wrapper is a proxy to Cognito. It does not validate credentials,
translate scopes, call Cognito Admin APIs, use Secrets Manager, or modify the
OAuth2 contract.

## Repository structure

```text
auth-platform/
├── .gitignore
├── .gitlab-ci.yml
├── AGENTS.md
├── README.md
├── docs/
│   └── implementation.md
├── src/
│   └── wrapper/
│       └── lambda_function.py
└── terraform/
    ├── .terraform.lock.hcl
    ├── apigateway.tf
    ├── backend.tf
    ├── cognito.tf
    ├── iam.tf
    ├── lambda.tf
    ├── logs.tf
    ├── outputs.tf
    ├── providers.tf
    ├── variables.tf
    └── versions.tf
```

## Terraform backend

Remote state uses an existing S3 backend:

```hcl
bucket       = "rogerio-iac-prod-us-east-1"
key          = "rogerio.piardi/terraform/auth-platform/prd.tfstate"
region       = "us-east-1"
use_lockfile = true
```

DynamoDB locking is not used.

The pipeline credential must be able to read and write:

```text
s3://rogerio-iac-prod-us-east-1/rogerio.piardi/terraform/auth-platform/prd.tfstate
s3://rogerio-iac-prod-us-east-1/rogerio.piardi/terraform/auth-platform/prd.tfstate.tflock
```

## Cognito

Implemented resources:

- Cognito User Pool: `auth-platform-m2m-user-pool`
- Cognito Resource Server: `m2m-prd`
- Cognito App Client: `auth-platform-m2m-client`
- Cognito AWS managed domain: `personal-rvpi-auth-platform`

OAuth flow:

```text
client_credentials
```

Scopes:

```text
m2m-prd/read
m2m-prd/write
```

Access token TTL:

```text
30 minutes
```

The Cognito client secret is managed by Cognito and is not exposed in Terraform
outputs.

## Lambda wrapper

Implemented file:

```text
src/wrapper/lambda_function.py
```

Lambda resource:

```text
auth-platform-lambda-wrapper
```

Runtime settings:

- runtime: `python3.12`
- package type: zip
- package source: `archive_file`
- timeout: 5 seconds
- memory: 256 MB
- HTTP timeout to Cognito: 4 seconds

Environment variables:

```text
COGNITO_TOKEN_URL
```

Behavior:

- accepts only `POST`
- returns `405` for unsupported methods
- returns `400` for empty body
- decodes base64 bodies from API Gateway when needed
- forwards `application/x-www-form-urlencoded` body to Cognito
- returns Cognito status, content type, and body
- returns `502` for Cognito communication failures or timeouts

The wrapper intentionally does not log client secrets, access tokens, full
request bodies, or sensitive headers.

## API Gateway

Implemented resources:

- API Gateway REST API: `auth-platform-api`
- Regional endpoint
- stage: `prd`
- resource path: `/token`
- method: `POST`
- integration: Lambda Proxy Integration
- authorization: `NONE`

Public custom domain endpoint:

```text
POST https://minha-api.freeddns.org/oauth/token
```

The API path is `/token`. The custom domain base path mapping is `oauth`, which
produces `/oauth/token`.

The Terraform code creates only the base path mapping for the existing custom
domain. It does not create API Gateway custom domain resources, ACM
certificates, DNS records, or certificate renewal automation.

## Logging

Terraform manages CloudWatch log groups with 14 days retention:

```text
/aws/lambda/auth-platform-lambda-wrapper
/aws/apigateway/auth-platform-access-logs
```

API Gateway access logs are enabled with JSON fields:

```json
{
  "requestId": "$context.requestId",
  "ip": "$context.identity.sourceIp",
  "httpMethod": "$context.httpMethod",
  "path": "$context.path",
  "status": "$context.status",
  "responseLength": "$context.responseLength",
  "integrationLatency": "$context.integrationLatency"
}
```

API Gateway execution logs are not enabled.

The AWS account already has an API Gateway CloudWatch role configured, so this
repository does not manage `aws_api_gateway_account`.

## IAM created by Terraform

Terraform creates a Lambda execution role:

```text
auth-platform-lambda-wrapper-role
```

The role only allows Lambda to write to its CloudWatch log group:

- `logs:CreateLogStream`
- `logs:PutLogEvents`

No permissions are added for Secrets Manager, DynamoDB, S3, or Cognito Admin
APIs.

## GitLab CI

The pipeline uses the official GitLab OpenTofu component:

```yaml
include:
  - component: gitlab.com/components/opentofu/full-pipeline@4.5.0
```

Configured inputs:

```yaml
version: 4.5.0
opentofu_version: 1.11.5
root_dir: terraform
state_name: auth-platform-prd
stage_build: plan
stage_deploy: apply
plan_extra_artifacts:
  - terraform/lambda_wrapper.zip
fmt_allow_failure: false
use_lockfile_for_cache_key: true
lockfile: readonly
destroy_rules:
  - when: never
delete_state_rules:
  - when: never
```

Important decisions:

- The pipeline uses OpenTofu, not Terraform.
- The provider lockfile is committed and was generated by OpenTofu.
- `lockfile: readonly` prevents CI from rewriting provider selections.
- `use_lockfile_for_cache_key: true` makes provider cache keys deterministic.
- `plan_extra_artifacts` includes `terraform/lambda_wrapper.zip` because the
  `archive_file` data source creates the ZIP during plan and the apply job runs
  in a different container.
- Destroy and delete-state jobs are explicitly disabled.

Required GitLab CI variables:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_DEFAULT_REGION=us-east-1
```

Optional for temporary credentials:

```text
AWS_SESSION_TOKEN
```

The variables should be protected. `AWS_SECRET_ACCESS_KEY` and
`AWS_SESSION_TOKEN` should be masked.

## Provider lockfile

The lockfile is:

```text
terraform/.terraform.lock.hcl
```

It must be generated with OpenTofu because the CI runs OpenTofu. The provider
sources in the lockfile use:

```text
registry.opentofu.org
```

Do not regenerate the lockfile for every infrastructure change. Regenerate it
only when provider requirements change, for example:

- adding a provider
- removing a provider
- changing provider version constraints
- intentionally upgrading providers with `tofu init -upgrade`

If the lockfile is generated with Terraform instead of OpenTofu, CI may fail
because Terraform uses `registry.terraform.io` in the lockfile and OpenTofu will
try to rewrite it.

## Suggested deploy policy

Use dedicated credentials for this project instead of sharing credentials with
other projects. The deployment principal can be a user or, preferably, a role.

Suggested inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::rogerio-iac-prod-us-east-1",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "rogerio.piardi/terraform/auth-platform/*"
          ]
        }
      }
    },
    {
      "Sid": "TerraformStateObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::rogerio-iac-prod-us-east-1/rogerio.piardi/terraform/auth-platform/prd.tfstate",
        "arn:aws:s3:::rogerio-iac-prod-us-east-1/rogerio.piardi/terraform/auth-platform/prd.tfstate.tflock"
      ]
    },
    {
      "Sid": "CognitoManagement",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:CreateUserPool",
        "cognito-idp:DeleteUserPool",
        "cognito-idp:DescribeUserPool",
        "cognito-idp:UpdateUserPool",
        "cognito-idp:GetUserPoolMfaConfig",
        "cognito-idp:SetUserPoolMfaConfig",
        "cognito-idp:ListTagsForResource",
        "cognito-idp:TagResource",
        "cognito-idp:UntagResource",
        "cognito-idp:CreateUserPoolClient",
        "cognito-idp:DeleteUserPoolClient",
        "cognito-idp:DescribeUserPoolClient",
        "cognito-idp:UpdateUserPoolClient",
        "cognito-idp:CreateResourceServer",
        "cognito-idp:DeleteResourceServer",
        "cognito-idp:DescribeResourceServer",
        "cognito-idp:UpdateResourceServer",
        "cognito-idp:CreateUserPoolDomain",
        "cognito-idp:DeleteUserPoolDomain",
        "cognito-idp:DescribeUserPoolDomain"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LambdaManagement",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:GetFunction",
        "lambda:GetFunctionCodeSigningConfig",
        "lambda:GetRuntimeManagementConfig",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:DeleteFunction",
        "lambda:AddPermission",
        "lambda:RemovePermission",
        "lambda:GetPolicy",
        "lambda:ListVersionsByFunction",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:ListTags"
      ],
      "Resource": "arn:aws:lambda:us-east-1:209479281611:function:auth-platform-lambda-wrapper"
    },
    {
      "Sid": "IamForLambdaRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:UpdateRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRolePolicies",
        "iam:GetRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole"
      ],
      "Resource": "arn:aws:iam::209479281611:role/auth-platform-lambda-wrapper-role"
    },
    {
      "Sid": "PassOnlyLambdaRoleToLambda",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::209479281611:role/auth-platform-lambda-wrapper-role",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "lambda.amazonaws.com"
        }
      }
    },
    {
      "Sid": "ApiGatewayManagement",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:PATCH",
        "apigateway:DELETE"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogsManagement",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
        "logs:TagResource",
        "logs:UntagResource",
        "logs:ListTagsForResource"
      ],
      "Resource": "*"
    }
  ]
}
```

Managed policies such as `AmazonAPIGatewayAdministrator`, `AWSLambdaRole`, and
`CloudWatchLogsFullAccess` are intentionally avoided initially because the
custom policy is narrower and easier to reason about.

If the state bucket uses SSE-KMS, add KMS permissions for the key used by the
bucket:

```text
kms:Decrypt
kms:Encrypt
kms:GenerateDataKey
kms:DescribeKey
```

## Client secret retrieval

Use Terraform outputs to get the User Pool ID and App Client ID:

```bash
cd terraform
tofu output user_pool_id
tofu output app_client_id
```

Then retrieve the secret manually:

```bash
aws cognito-idp describe-user-pool-client \
  --region us-east-1 \
  --user-pool-id <user_pool_id> \
  --client-id <app_client_id> \
  --query 'UserPoolClient.ClientSecret' \
  --output text
```

The client secret must not be committed, printed in Terraform outputs, or logged
by the Lambda wrapper.

## Token request

Expected content type:

```text
application/x-www-form-urlencoded
```

Request fields:

```text
grant_type=client_credentials
client_id=<app_client_id>
client_secret=<client_secret>
scope=m2m-prd/read
```

Example:

```bash
curl -X POST "https://minha-api.freeddns.org/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<app_client_id>&client_secret=<client_secret>&scope=m2m-prd/read"
```

## Troubleshooting history

### Pipeline rejected `opentofu_version: 1.11.6`

The component version `4.5.0` does not allow OpenTofu `1.11.6`. The pipeline was
changed to:

```yaml
opentofu_version: 1.11.5
```

### Lockfile failed with `lockfile: readonly`

The initial lockfile was generated with Terraform and used
`registry.terraform.io`. OpenTofu attempted to rewrite it to
`registry.opentofu.org`, but the pipeline was configured with:

```yaml
lockfile: readonly
```

The fix was to regenerate and commit the lockfile with OpenTofu.

### S3 backend returned 403 in plan

The failure happened during:

```text
gitlab-tofu plan
```

OpenTofu successfully configured the S3 backend, then failed on `HeadObject` for
the remote state object. The cause was missing or wrong S3 permissions for:

```text
s3://rogerio-iac-prod-us-east-1/rogerio.piardi/terraform/auth-platform/prd.tfstate
```

### Apply failed on Cognito MFA config

The provider created the User Pool and then attempted to read MFA configuration.
The deploy policy was missing:

```text
cognito-idp:GetUserPoolMfaConfig
```

### Apply failed because `lambda_wrapper.zip` was missing

The `archive_file` data source creates:

```text
terraform/lambda_wrapper.zip
```

The plan job created that ZIP, but the apply job runs in another container. The
fix was to pass the ZIP as an extra artifact:

```yaml
plan_extra_artifacts:
  - terraform/lambda_wrapper.zip
```

## Validation commands

Local validation with OpenTofu:

```bash
cd terraform
tofu fmt -check
tofu init
tofu validate
tofu plan
```

If OpenTofu is not installed locally but Docker is available, use the same image
as GitLab CI:

```bash
docker run --rm \
  -v "$PWD":/work \
  -w /work/terraform \
  registry.gitlab.com/components/opentofu/gitlab-opentofu:4.5.0-opentofu1.11.5-alpine \
  tofu validate
```

## Explicit non-goals

This project intentionally does not implement:

- business API endpoints
- Lambda Authorizer
- Cognito Authorizer for business APIs
- `/hello` endpoint
- OpenAPI import
- Secrets Manager for Cognito client secret
- DynamoDB lock table
- API Gateway custom domain creation
- ACM certificate creation
- DNS records
- Cognito custom domain
- multiple Cognito App Clients
- scope translation
- Terraform submodules
- CORS
