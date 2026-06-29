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

## Partner Identity (Approach A)

A Pre Token Generation V3 trigger resolves the calling M2M client to a partner
identity at access-token issuance and injects it as signed access-token claims
(`partner_id`, `tenant`). The business API consumes these claims without any
lookup. The trigger reads identity from the `auth-partners` DynamoDB table.

### Provision a partner

The table is keyed by `client_id`. Each record must carry a non-empty
`partner_id` and `tenant`:

```json
{ "client_id": "<app_client_id>", "partner_id": "PARTNER-001", "tenant": "acme" }
```

Create or update a record with AWS CLI (no redeploy needed — changes propagate
within the trigger cache TTL, 300s by default):

```bash
aws dynamodb put-item \
  --region us-east-1 \
  --table-name auth-partners \
  --item '{
    "client_id":  {"S": "<app_client_id>"},
    "partner_id": {"S": "PARTNER-001"},
    "tenant":     {"S": "acme"}
  }'
```

Inspect a record:

```bash
aws dynamodb get-item \
  --region us-east-1 \
  --table-name auth-partners \
  --key '{"client_id": {"S": "<app_client_id>"}}'
```

### Fail-closed behavior

A client with no record, or a record missing `partner_id`/`tenant`, is rejected
by the trigger and **no token is issued** (`/oauth/token` returns a generic
error). Provision every M2M client before it requests a token.

### Requirements

- The User Pool must be on the **Essentials** (or Plus) tier — the V3_0 event
  used for M2M access-token customization does not fire on the Lite tier, and
  M2M V3 customization is billed separately from MAU.
- The deploy role `AuthPlatformGitHubDeployer` needs permissions to manage the
  new resources: `dynamodb:*` on the `auth-partners` table (CreateTable,
  DescribeTable, DescribeContinuousBackups, UpdateContinuousBackups,
  TagResource, ListTagsOfResource, UpdateTable, DeleteTable) and IAM role
  management for `auth-platform-lambda-pretoken-role` (CreateRole, GetRole,
  PutRolePolicy, GetRolePolicy, ListRolePolicies, DeleteRolePolicy, PassRole,
  TagRole, DeleteRole), plus `lambda:CreateFunction`/`AddPermission` and
  `cognito-idp:UpdateUserPool`.

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
