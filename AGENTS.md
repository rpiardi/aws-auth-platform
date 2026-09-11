# AGENTS.md

## Project Overview

This repository contains the infrastructure and Lambda code for the `auth-platform` project.

The goal is to provide an AWS-based Machine-to-Machine (M2M) authentication platform using:

- Amazon Cognito (User Pool with Essentials tier and Pre Token Generation V3_0 trigger)
- Amazon API Gateway (REST API with Regional endpoint and custom domain base path mapping)
- AWS Lambda (Python 3.12: proxy wrapper and pretoken trigger)
- Amazon DynamoDB (on-demand partner identity lookup table)
- OpenTofu / Terraform (IaC with remote S3 backend and native state locking)
- GitHub Actions (CI/CD using AWS OIDC authentication)

**Strict Scope Boundary**: This repository implements authentication only. Do not implement business APIs, internal microservice proxies, or business authorizers in this repository.

---

# Architecture Summary

Request and enrichment flow:

```text
Consumer (M2M Client)
   ↓ POST client_id + client_secret + scope (application/x-www-form-urlencoded)
API Gateway REST API (Regional)
   ↓ [POST /token mapped to custom domain https://minha-api.freeddns.org/oauth/token]
Lambda Proxy Wrapper (auth-platform-lambda-wrapper)
   ↓ [forwards body to Cognito /oauth2/token, timeout: 4s]
Cognito /oauth2/token
   ↓ Pre Token Generation V3_0 trigger (auth-platform-lambda-pretoken)
   ↓    resolves client_id → {partner_id, tenant} from DynamoDB (auth-partners)
   ↓    injects partner_id + tenant as access-token claims (fail-closed)
   ↓
JWT Access Token (signed RS256, carrying partner_id + tenant claims)
   ↓
Returned to Consumer via Lambda Wrapper & API Gateway
```

### Component Roles & Boundaries

1. **Lambda Wrapper (`auth-platform-lambda-wrapper`)**:
   - Pure, transparent proxy to Cognito's `/oauth2/token` endpoint.
   - Preserves the OAuth2 contract.
   - Must NOT: validate credentials, translate scopes, call Cognito Admin APIs, use Secrets Manager, or alter token responses.

2. **Pre Token Generation Trigger (`auth-platform-lambda-pretoken`)**:
   - Executes inside Cognito token issuance flow (`TokenGeneration_ClientCredentials`).
   - Resolves `client_id` to `{partner_id, tenant}` via DynamoDB `auth-partners`.
   - Uses an in-memory cache for positive (300s) and negative (30s) lookups to optimize warm executions.
   - Injects claims into `accessTokenGeneration.claimsToAddOrOverride`.
   - **Fails closed**: If the client is unknown, disabled, or an error occurs, it raises an exception so Cognito aborts token issuance.

---

# Technology Stack & Specifications

| Component | Technology | Specification / Configuration |
|---|---|---|
| **Cloud Provider** | AWS | Region: `us-east-1` |
| **IaC Engine** | OpenTofu | Version: `1.11.5` (strict CI requirement) |
| **Providers** | OpenTofu Registry | `hashicorp/aws` (~> 5.0), `hashicorp/archive` (~> 2.7) |
| **State Backend** | Amazon S3 | Bucket: `rogerio-iac-prod-us-east-1`<br>Key: `rogerio.piardi/terraform/auth-platform/prd.tfstate`<br>Locking: Native S3 (`use_lockfile = true`, NO DynamoDB lock table) |
| **Identity Provider** | Amazon Cognito | User Pool: `auth-platform-m2m-user-pool`<br>Tier: `ESSENTIALS` (required for V3_0 machine identities)<br>Trigger: Pre Token Generation `V3_0`<br>Resource Server: `m2m-prd` (scopes: `read`, `write`)<br>App Client: `auth-platform-m2m-client` (`client_credentials`, 30 min TTL)<br>Domain Prefix: `personal-rvpi-auth-platform` |
| **API Gateway** | Amazon API Gateway | Type: REST API (`auth-platform-api`), Regional<br>Stage: `prd`<br>Endpoint: `POST /token` with Lambda Proxy Integration<br>Custom Domain: `minha-api.freeddns.org`<br>Base Path Mapping: `oauth` (Produces: `/oauth/token`) |
| **Compute (Functions)** | AWS Lambda | Runtime: `python3.12`<br>Architecture: x86_64<br>Memory: 256 MB, Timeout: 5s<br>Packaging: zip via `archive_file` |
| **Data Store** | Amazon DynamoDB | Table: `auth-partners`<br>Billing: `PAY_PER_REQUEST` (on-demand)<br>Primary Key: `client_id` (String)<br>PITR: Enabled |
| **Observability** | Amazon CloudWatch | Retention: 14 days<br>Groups: `/aws/lambda/auth-platform-lambda-wrapper`, `/aws/lambda/auth-platform-lambda-pretoken`, `/aws/apigateway/auth-platform-access-logs`<br>API GW Access Logs: Structured JSON format |
| **CI/CD** | GitHub Actions | Workflows: `opentofu-ci.yml`, `opentofu-deploy.yml`<br>Auth: AWS OIDC via Role `arn:aws:iam::209479281611:role/AuthPlatformGitHubDeployer`<br>Environment: `prd` |

---

# Repository Structure

```text
auth-platform/
├── AGENTS.md                          # Governance, coding standards & rules for agents
├── README.md                          # Operational overview & quickstart
├── docs/
│   ├── archive/
│   │   └── gitlab-ci.yml              # Archived historical reference (DO NOT RESTORE)
│   ├── implementation.md              # Detailed architectural notes & operational record
│   ├── decisoes-abordagens-m2m.md     # Architecture decisions for partner enrichment
│   ├── spec-abordagens-A-C-D.md       # Comparative analysis of M2M architectures
│   ├── spec-layer-enriquecimento-parceiro.md
│   └── spec-proxy-por-verbo.md
│
├── .github/
│   └── workflows/
│       ├── opentofu-ci.yml            # PR check: tofu fmt + tofu validate
│       ├── opentofu-deploy.yml        # Manual dispatch: tofu plan / tofu apply (prd)
│       └── test-aws-oidc.yml          # GitHub OIDC connectivity test
│
├── terraform/
│   ├── .terraform.lock.hcl            # OpenTofu provider lockfile (registry.opentofu.org)
│   ├── backend.tf                     # S3 backend with use_lockfile = true
│   ├── versions.tf                    # OpenTofu & provider version constraints
│   ├── providers.tf                   # AWS provider with default tags
│   ├── variables.tf                   # Input variables with sensible defaults
│   ├── outputs.tf                     # Safe public outputs (NO secrets)
│   ├── cognito.tf                     # User Pool Essentials, Resource Server, Client, Domain
│   ├── dynamodb.tf                    # auth-partners DynamoDB table
│   ├── lambda.tf                      # Lambda wrapper, pretoken trigger & permissions
│   ├── apigateway.tf                  # REST API, /token resource, stage & base path mapping
│   ├── iam.tf                         # Least-privilege Lambda execution roles and policies
│   └── logs.tf                        # CloudWatch log groups (14-day retention)
│
└── src/
    ├── wrapper/
    │   └── lambda_function.py         # HTTP proxy Lambda forwarding to Cognito /oauth2/token
    └── pretoken/
        └── lambda_function.py         # Pre Token Generation V3_0 claim enrichment trigger
```

---

# Naming Conventions & Tagging

### Resource Naming
- Use lowercase kebab-case prefixed with the project name: `<project>-<resource>`.
- Examples:
  - `auth-platform-api`
  - `auth-platform-lambda-wrapper`
  - `auth-platform-lambda-wrapper-role`
  - `auth-platform-lambda-pretoken`
  - `auth-platform-lambda-pretoken-role`
  - `auth-platform-m2m-user-pool`
  - `auth-platform-m2m-client`
- **Do not** include the `aws-` prefix in resource names.
- **Do not** include the `prd` stage suffix in resource names unless required by AWS global/regional uniqueness constraints (e.g., `m2m-prd` resource server identifier).

### Resource Tagging
- Tagging must remain minimal and uniform:
  ```hcl
  tags = {
    Project = "auth-platform"
  }
  ```
- Handled globally via `default_tags` in `terraform/providers.tf`.

---

# Coding Standards & Patterns

## Python Standards (Lambdas)

1. **Runtime & Dependencies**:
   - Runtime: `python3.12`.
   - Use Python Standard Library wherever possible.
   - For `wrapper`: Standard library only (`urllib.request`, `urllib.error`, `json`, `os`, `base64`). Zero external dependencies.
   - For `pretoken`: Standard library + `boto3` (available in AWS Lambda runtime). Zero third-party pip dependencies.
   - Do NOT introduce `pip`, `poetry`, virtualenvs, Docker packaging, or third-party wheels without explicit approval.

2. **Error Handling & HTTP Contract**:
   - `wrapper`:
     - Accepts only `POST` → returns `405` with `{"error": "method_not_allowed"}` for others.
     - Rejects empty bodies → returns `400` with `{"error": "invalid_request", "error_description": "empty body"}`.
     - Decodes base64-encoded bodies from API Gateway if `event.get("isBase64Encoded")` is true.
     - Forwards raw HTTP status and headers from Cognito.
     - Handles timeouts and connection errors → returns `502` with `{"error": "bad_gateway", "error_description": "cognito communication failure"}`.
     - Strict timeout discipline: HTTP request timeout is `4` seconds, strictly shorter than the Lambda `5` seconds timeout.
   - `pretoken`:
     - Validates `triggerSource == "TokenGeneration_ClientCredentials"`.
     - **Fail-closed**: Raises an exception if client is not found in DynamoDB or trigger source is invalid. Raising an exception prevents Cognito from issuing the token.
     - Emits structured JSON events for resolution or rejection (`pretoken_resolved`, `pretoken_rejected`).

3. **In-Memory Caching Pattern (`src/pretoken/lambda_function.py`)**:
   - Cache lookup results in a module-scoped dict to avoid DynamoDB round-trips on warm invocations:
     - Positive cache TTL: configurable via `PARTNERS_CACHE_TTL` (default `300` seconds).
     - Negative cache TTL: short duration (`30` seconds) to protect against hammering DynamoDB for invalid clients while allowing prompt recovery after provisioning.

4. **Logging & Zero-Secret-Leakage Policy**:
   - Use structured JSON logging.
   - **ABSOLUTE RULE**: Never log:
     - Client secrets
     - Access tokens or refresh tokens
     - The `Authorization` header
     - Raw HTTP request bodies
     - Full DynamoDB partner record dumps
   - Only log operational metadata: event name, request IDs, partner ID, tenant, and HTTP statuses.

5. **Code Style & Syntax Verification**:
   - Follow PEP 8 formatting.
   - Code must compile cleanly:
     ```bash
     python3 -m py_compile src/wrapper/lambda_function.py src/pretoken/lambda_function.py
     ```

## Terraform / OpenTofu Standards

1. **Tooling & Versioning**:
   - Engine: OpenTofu `1.11.5`.
   - Providers:
     - `hashicorp/aws ~> 5.0`
     - `hashicorp/archive ~> 2.7`
   - Provider Lockfile (`.terraform.lock.hcl`):
     - Must be locked to `registry.opentofu.org`.
     - **Never** regenerate the lockfile using standard `terraform` CLI, as it rewrites registry sources to `registry.terraform.io` and breaks CI.
     - Only update lockfile with `tofu init -upgrade`.

2. **File Organization & Responsibility**:
   - Keep all infrastructure code inside `terraform/`.
   - Do NOT create Terraform submodules unless explicitly directed. Keep flat, declarative, and easily auditable.
   - Separation of files:
     - `backend.tf`: S3 backend configuration only.
     - `versions.tf`: OpenTofu and provider version constraints.
     - `providers.tf`: Provider setup and `default_tags`.
     - `variables.tf`: Input variable definitions with types and descriptions.
     - `outputs.tf`: Output declarations.
     - `cognito.tf`: Cognito User Pool, Client, Resource Server, and Domain.
     - `dynamodb.tf`: DynamoDB tables.
     - `lambda.tf`: Lambda functions, zip archives, and invoke permissions.
     - `apigateway.tf`: REST API, resources, methods, integrations, stages, base path mapping.
     - `iam.tf`: Roles and scoped policies for Lambda functions.
     - `logs.tf`: CloudWatch log groups and retention settings.

3. **Variables & Parameters**:
   - Provide explicit types and sensible defaults for configurable parameters.
   - Do not over-parameterize immutable architectural choices (such as Regional REST API, client_credentials flow, standard scopes, or form-urlencoded encoding).

4. **Outputs**:
   - Expose only non-sensitive operational identifiers:
     - `user_pool_id`
     - `user_pool_arn`
     - `app_client_id`
     - `cognito_token_url`
     - `auth_api_id`
     - `auth_api_invoke_url`
     - `auth_api_custom_domain_url`
   - **Never** expose the Cognito App Client Secret in Terraform outputs.

---

# Security & IAM Guidelines

1. **Principle of Least Privilege**:
   - Do not use wildcard actions (`*`) or wildcard resources (`*`) where a specific action or ARN can be specified.
   - `auth-platform-lambda-wrapper-role`:
     - Granted ONLY CloudWatch log creation permissions (`logs:CreateLogStream`, `logs:PutLogEvents`).
     - NO permissions for DynamoDB, Secrets Manager, S3, or Cognito Admin APIs.
   - `auth-platform-lambda-pretoken-role`:
     - Granted CloudWatch log creation permissions.
     - **Deliberate Scoped Exception**: Granted `dynamodb:GetItem` exclusively on `arn:aws:dynamodb:*:*:table/auth-partners`. No PutItem, UpdateItem, Scan, or DeleteItem permissions.
   - API Gateway execution role: AWS account already has `arn:aws:iam::209479281611:role/api-gateway-cloudwatch-role`. Do not declare `aws_api_gateway_account` in Terraform.

2. **Credentials & Secrets**:
   - Do not store long-lived AWS credentials in GitHub repository secrets.
   - CI/CD authenticates to AWS exclusively through GitHub OIDC using `vars.AWS_ROLE_ARN`.
   - Cognito client secret is managed inside Cognito; retrieve it manually via AWS CLI (see Runbook below).

---

# CI/CD & GitHub Actions

GitHub is the single source of truth and GitHub Actions is the only active CI/CD platform.

Workflows:
- `.github/workflows/opentofu-ci.yml`:
  - Triggers on pull requests.
  - Runs `tofu fmt -check -recursive`.
  - Runs `tofu init -backend=false -input=false -lockfile=readonly`.
  - Runs `tofu validate`.
  - Both checks are strictly required by the protected `main` branch.
- `.github/workflows/opentofu-deploy.yml`:
  - Manual execution via `workflow_dispatch`.
  - Inputs: `operation` (`plan` or `apply`).
  - Restricted to protected `main` branch under the `prd` environment.
  - Concurrency group: `auth-platform-prd-state` (canceling in progress = false).
  - Uses OpenTofu `1.11.5`.
  - Authenticates via OIDC to `arn:aws:iam::209479281611:role/AuthPlatformGitHubDeployer`.
  - In `apply` mode, generates and applies the plan within the same job. Never uploads the plan as an external artifact.
- `.github/workflows/test-aws-oidc.yml`:
  - Diagnostic workflow to verify OIDC STS role assumption.

*Legacy Notice*: The GitLab CI configuration is archived in `docs/archive/gitlab-ci.yml`. It is historical reference only. Do NOT restore or re-enable GitLab CI.

---

# Rules for Autonomous Agents

Autonomous agents operating in this repository MUST follow these rules without exception:

1. **Scope Adherence**:
   - Never implement business APIs, authorizers for business backends, `/hello` endpoints, or internal proxies in this repository.
   - Any enrichment logic outside the Pre Token Generation trigger (e.g. proxying internal Kubernetes/Istio workloads) belongs to external repositories.

2. **Security & Zero Leakage**:
   - Never print or commit Cognito App Client secrets or generated access tokens.
   - Maintain the fail-closed security model in all authentication code.
   - Never add broad IAM permissions (`*`) or grant unnecessary AWS service access.

3. **Tooling & Dependency Discipline**:
   - Always execute commands using `tofu` (OpenTofu `1.11.5`).
   - Do NOT run `terraform init` if it alters `.terraform.lock.hcl` provider addresses away from `registry.opentofu.org`.
   - Do NOT introduce Makefiles, Docker containers, npm packages, or external Python libraries.

4. **Mandatory Pre-Completion Verification Checklist**:
   Before submitting any code changes or completing a task, you MUST run and verify:
   ```bash
   # 1. Format check
   tofu fmt -check -recursive

   # 2. Syntax & configuration validation
   cd terraform
   tofu init -backend=false -input=false -lockfile=readonly
   tofu validate
   cd ..

   # 3. Python compilation check
   python3 -m py_compile src/wrapper/lambda_function.py src/pretoken/lambda_function.py
   ```

5. **Git Conventions**:
   - Work on descriptive branches (`feature/...`, `fix/...`, `docs/...`, `chore/...`).
   - Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).
   - Ensure the working tree is clean after changes.

---

# Explicit Non-Goals

Do **NOT** implement:
- Business platform endpoints or internal microservices
- Lambda Authorizers or Cognito Authorizers for business APIs
- OpenAPI / Swagger imports in API Gateway
- Secrets Manager integration for the Cognito client secret
- DynamoDB lock table for Terraform (native S3 locking with `use_lockfile = true` is used)
- API Gateway custom domain creation, ACM certificates, or DNS records (existing domain mapping only)
- Cognito custom domains
- Multiple Cognito App Clients (single M2M client only)
- Scope translation or OAuth2 contract modifications
- Terraform submodules
- CORS configuration on API Gateway

---

# Operational Runbook

### Local Validation Commands
```bash
cd terraform
tofu fmt -check
tofu init
tofu validate
tofu plan
```

### Retrieving the Cognito Client Secret
```bash
aws cognito-idp describe-user-pool-client \
  --region us-east-1 \
  --user-pool-id <user_pool_id> \
  --client-id <app_client_id> \
  --query 'UserPoolClient.ClientSecret' \
  --output text
```

### Generating an M2M Token via cURL
```bash
curl -X POST "https://minha-api.freeddns.org/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<app_client_id>&client_secret=<client_secret>&scope=m2m-prd/read"
```
