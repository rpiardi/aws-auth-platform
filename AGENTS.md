# AGENTS.md

## Project

This repository contains the infrastructure and Lambda code for the `auth-platform` project.

The goal is to provide an AWS-based M2M authentication platform using:

- Amazon Cognito
- API Gateway REST API
- AWS Lambda Wrapper
- Terraform

The initial scope is authentication only.

Do not implement business APIs in this repository.

---

# Architecture Summary

Request flow:

```text
Consumer
   ↓ client_id + client_secret + scope
API Gateway Auth
   ↓
Lambda Wrapper
   ↓
Cognito /oauth2/token
   ↓
JWT Access Token
```

The Lambda Wrapper is a pure proxy to Cognito's `/oauth2/token` endpoint.

It must not:

- validate credentials;
- translate scopes;
- use Secrets Manager;
- use Cognito Admin APIs;
- modify the OAuth2 contract.

---

# AWS Region

Use:

```text
us-east-1
```

---

# Terraform Backend

Use the existing S3 backend:

```text
bucket = rogerio-iac-prod-us-east-1
key    = rogerio.piardi/terraform/auth-platform/prd.tfstate
region = us-east-1
```

Use:

```hcl
use_lockfile = true
```

Do not create DynamoDB for Terraform locking.

---

# Repository Structure

Expected structure:

```text
auth-platform/
├── AGENTS.md
├── README.md
├── .github/
│   └── workflows/
│       ├── opentofu-ci.yml
│       ├── opentofu-deploy.yml
│       └── test-aws-oidc.yml
│
├── terraform/
│   ├── backend.tf
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cognito.tf
│   ├── lambda.tf
│   ├── apigateway.tf
│   ├── iam.tf
│   └── logs.tf
│
└── src/
    └── wrapper/
        └── lambda_function.py
```

Do not create Terraform submodules unless explicitly requested.

Keep all Terraform files inside the `terraform/` directory.

---

# Naming Convention

Use concise resource names based on:

```text
<project>-<resource>
```

Examples:

```text
auth-platform-api
auth-platform-lambda-wrapper
auth-platform-lambda-wrapper-role
auth-platform-m2m-user-pool
```

Do not include the `aws-` prefix in resource names.

Do not include the `prd` stage in resource names unless required by AWS uniqueness constraints.

---

# Tags

Use only:

```text
Project = auth-platform
```

---

# Terraform Guidelines

Use Terraform files by responsibility:

- `backend.tf`
- `versions.tf`
- `providers.tf`
- `variables.tf`
- `outputs.tf`
- `cognito.tf`
- `lambda.tf`
- `apigateway.tf`
- `iam.tf`
- `logs.tf`

Prefer variables with defaults for configurable values.

Suggested variables:

- AWS region
- project name
- stage name
- Cognito domain prefix
- resource server identifier
- access token TTL
- Lambda timeout
- Lambda memory
- log retention days
- custom domain name
- custom domain base path

Do not over-parameterize structural decisions such as:

- REST API usage
- Regional endpoint type
- OAuth flow `client_credentials`
- scopes `read` and `write`
- `application/x-www-form-urlencoded` contract
- Lambda Proxy Integration

---

# GitHub Actions

GitHub is the primary repository and GitHub Actions is the only active CI/CD
system.

Workflow files:

```text
.github/workflows/opentofu-ci.yml
.github/workflows/opentofu-deploy.yml
.github/workflows/test-aws-oidc.yml
```

The workflows must:

- use OpenTofu `1.11.5`;
- run `tofu fmt -check -recursive` and `tofu validate` on every pull request;
- initialize validation with `-backend=false` and `-lockfile=readonly`;
- keep `plan` and `apply` manually triggered with `workflow_dispatch`;
- run deployment only from the protected `main` branch;
- use the GitHub environment `prd`;
- authenticate to AWS through OIDC using `vars.AWS_ROLE_ARN`;
- serialize state operations with the `auth-platform-prd-state` concurrency group;
- generate and apply the saved plan in the same job;
- never expose the saved plan as a public artifact.

AWS role:

```text
arn:aws:iam::209479281611:role/AuthPlatformGitHubDeployer
```

Do not store long-lived AWS access keys in GitHub.

The archived GitLab pipeline is historical reference only:

```text
docs/archive/gitlab-ci.yml
```

Do not restore `.gitlab-ci.yml` or run deployment pipelines from GitLab.

Do not create complex CI/CD automation initially.

Do not introduce:

- custom Docker images;
- Makefiles;
- multi-environment promotion flows;
- automatic apply on every commit;
- business API deployment steps.

Keep the workflows minimal and operational.

---

# Terraform Outputs

Expose the following Terraform outputs:

```text
user_pool_id
user_pool_arn
app_client_id
cognito_token_url
auth_api_id
auth_api_invoke_url
auth_api_custom_domain_url
```

Do not expose the Cognito App Client secret in Terraform outputs.

---

# Cognito Requirements

Create:

- Cognito User Pool
- Cognito Resource Server
- Cognito App Client
- Cognito AWS managed domain

User Pool name:

```text
auth-platform-m2m-user-pool
```

Resource Server identifier:

```text
m2m-prd
```

Scopes:

```text
read
write
```

Expected scopes:

```text
m2m-prd/read
m2m-prd/write
```

OAuth flow:

```text
client_credentials
```

Access token TTL:

```text
30 minutes
```

Cognito domain prefix:

```text
personal-rvpi-auth-platform
```

Do not implement scope translation.

---

# Client Secret Handling

Do not output the Cognito App Client secret.

Do not use Secrets Manager initially.

The client secret remains managed by Cognito and may be retrieved manually through AWS Console or AWS CLI.

---

# Lambda Wrapper Requirements

Lambda name:

```text
auth-platform-lambda-wrapper
```

Runtime:

```text
Python
```

Package type:

```text
zip
```

Packaging strategy:

```text
archive_file
```

Timeout:

```text
5 seconds
```

Memory:

```text
256 MB
```

The Lambda Wrapper must:

- receive `application/x-www-form-urlencoded` requests;
- forward the request body to Cognito `/oauth2/token`;
- preserve the OAuth2 contract;
- return Cognito's response.

Implementation guidelines:

- use Python standard library;
- use `urllib.request` for HTTP calls;
- read Cognito URL from `COGNITO_TOKEN_URL` environment variable;
- use HTTP timeout shorter than Lambda timeout;
- suggested HTTP timeout: 4 seconds.

Suggested internal flow:

```text
API Gateway event
   ↓
validate HTTP method
   ↓
read request body
   ↓
decode base64 body if needed
   ↓
forward request to Cognito
   ↓
return Cognito response
```

The Lambda should:

- accept only `POST`;
- return `405` for unsupported methods;
- return `400` for empty body;
- return `502` for Cognito communication failure or timeout.

Never log:

- client secrets;
- access tokens;
- full request bodies;
- sensitive headers.

Do not add external dependencies unless explicitly requested.

---

# API Gateway Requirements

Create an API Gateway REST API.

API name:

```text
auth-platform-api
```

Endpoint type:

```text
Regional
```

Stage:

```text
prd
```

Do not configure authentication in API Gateway.

Security is provided by Cognito OAuth2 `client_credentials`.

Do not configure CORS.

Use:

```text
Lambda Proxy Integration
```

Public endpoint:

```text
POST https://minha-api.freeddns.org/oauth/token
```

Do not use OpenAPI import.

Create API Gateway resources directly in Terraform.

Do not create business endpoints.

---

# Custom Domain Requirements

Use the existing API Gateway custom domain:

```text
minha-api.freeddns.org
```

Use base path:

```text
oauth
```

Terraform must create only the base path mapping.

Do not create:

- API Gateway custom domain;
- ACM certificate;
- DNS records;
- certificate renewal automation.

---

# Logging Requirements

CloudWatch log retention:

```text
14 days
```

Create and manage CloudWatch Log Groups with Terraform.

Enable API Gateway access logs.

Use JSON log format similar to:

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

Do not enable API Gateway execution logs initially.

---

# API Gateway CloudWatch Role

The AWS account already has a configured API Gateway CloudWatch role:

```text
arn:aws:iam::209479281611:role/api-gateway-cloudwatch-role
```

Do not create or modify `aws_api_gateway_account`.

---

# IAM Guidelines

Follow least privilege.

Avoid:

```text
Action = "*"
Resource = "*"
```

unless strictly necessary.

The Lambda execution role should contain only CloudWatch logging permissions.

Do not add permissions for:

- Secrets Manager
- DynamoDB
- S3
- Cognito Admin APIs

unless explicitly requested.

---

# README Requirements

The repository README should contain:

- Terraform/OpenTofu init/plan/apply commands
- GitHub Actions overview using OpenTofu
- GitHub OIDC role and environment requirements
- how to retrieve Cognito client secret via AWS CLI
- curl example for token generation
- expected OAuth token request format

Keep the README concise and operational.

---

# Explicit Non-Goals

Do not implement:

- business-platform resources;
- Lambda Authorizer;
- Cognito Authorizer for business APIs;
- `/hello` endpoint;
- OpenAPI import;
- Secrets Manager for Cognito client secret;
- DynamoDB Terraform lock table;
- API Gateway custom domain creation;
- ACM certificate creation;
- DNS records;
- Cognito custom domain;
- multiple Cognito App Clients;
- scope translation;
- Terraform submodules;
- CORS.

---

# Implementation Style

Keep the implementation simple and readable.

Prefer explicit Terraform resources over abstractions.

Avoid premature modularization.

Do not introduce Docker, Makefiles, or extra tooling unless explicitly requested.

The only active CI/CD is the GitHub Actions OpenTofu workflow described above.

When uncertain, prefer the simplest implementation matching this document.
