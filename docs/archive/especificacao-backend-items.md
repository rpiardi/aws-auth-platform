# Especificação Técnica — Backend `items` (business API)

**API:** `sample-api/v1`
**Padrão:** API Gateway (REST) → Lambda-proxy por verbo → DynamoDB
**Autenticação:** Cognito User Pool (M2M `client_credentials`) provido pela `auth-platform`
**Região / Conta:** `us-east-1` / `209479281611`
**Versão do documento:** 2.0

---

## 1. Visão geral

Backend serverless para o recurso `items`, exposto via API Gateway REST. Cada verbo HTTP é atendido por uma Lambda-proxy dedicada que acessa o DynamoDB diretamente (sem backend HTTP separado, sem encadeamento lambda→lambda). A lógica comum vive em uma **Lambda Layer** compartilhada.

Esta é a **business API** e é **complementar à `auth-platform`**: ela não implementa nada de Cognito — apenas **consome** o User Pool M2M já criado naquele repositório para validar tokens. Modelo de dados deliberadamente simples: `id`, `description`, `status`. Sem tenant/partner nesta versão.

**Premissas de custo/operação:**
- Compute escala a zero (Lambda); custo ocioso ~zero.
- DynamoDB on-demand: sem instância 24/7, sem provisionamento de capacidade.
- DynamoDB é API AWS acessível por IAM → **sem NAT Gateway**. Em VPC, usar **Gateway VPC Endpoint** para DynamoDB (gratuito).

---

## 2. Arquitetura

### 2.1 Fluxo ponta a ponta (com a auth-platform)

```text
                    ┌──────────────────────────────────────────────┐
                    │              auth-platform (repo A)           │
  Consumer ──┐      │  POST https://minha-api.freeddns.org/oauth/token
   (client_  │      │     → Lambda Wrapper → Cognito /oauth2/token  │
    id +     ├─(1)─►│     ← JWT access token (scope: m2m-prd/read    │
    secret + │      │                              e/ou m2m-prd/write)│
    scope)   │      └──────────────────────────────────────────────┘
             │
             │      ┌──────────────────────────────────────────────┐
             └─(2)─►│             business-platform (repo B)        │
  Authorization:    │  API Gateway REST  →  Cognito Authorizer       │
  Bearer <token>    │     (valida assinatura/exp + scope do método)  │
                    │           ↓ (token e scope OK)                 │
                    │     Request Validator (valida corpo/JSON Schema)│
                    │           ↓ (corpo OK)                         │
                    │     Lambda-proxy (por verbo) → DynamoDB        │
                    └──────────────────────────────────────────────┘
```

1. O consumer obtém o token na `auth-platform`.
2. Chama a business API com `Authorization: Bearer <token>`. O gateway valida **token + scope** e depois **contrato** antes de invocar a Lambda.

### 2.2 Detalhe da business API

```text
                          ┌─────────────────────────────┐
                          │     Lambda Layer (comum)     │
                          │  - repositório DynamoDB       │
                          │  - validação (defesa)         │
                          │  - geração de id (UUID)       │
                          │  - helpers de resposta/erro   │
                          └──────────────┬──────────────┘
                                         │ (montada em cada função)
   API Gateway REST          Lambda-proxy (1 por verbo)        DynamoDB
   ─────────────────         ─────────────────────────         ────────
   POST   /items      ─────► items-post    ───────────────►  PutItem
   GET    /items      ─────► items-get     ───────────────►  Scan
   GET    /items/{id} ─────► items-get     ───────────────►  GetItem
   PUT    /items/{id} ─────► items-put     ───────────────►  PutItem (upsert)
   PATCH  /items/{id} ─────► items-patch   ───────────────►  UpdateItem (condicional)
   DELETE /items/{id} ─────► items-delete  ───────────────►  DeleteItem
```

As duas rotas GET são atendidas pela **mesma função** (`items-get`), que roteia internamente pela presença do path parameter `id`.

---

## 3. Modelo de dados

| Campo         | Tipo    | Obrigatório | Observação                                   |
|---------------|---------|-------------|----------------------------------------------|
| `id`          | string  | sim         | Chave. UUID v4 gerado pelo serviço no POST.  |
| `description` | string  | sim         | Texto livre, não vazio.                       |
| `status`      | boolean | sim         | `true` = ativo, `false` = inativo.            |

Exemplo:

```json
{
  "id": "9f1c2e4a-7b3d-4f8e-a1c2-0b9d8e7f6a5c",
  "description": "Item de exemplo",
  "status": true
}
```

---

## 4. Tabela DynamoDB

| Propriedade   | Valor        |
|---------------|--------------|
| Nome          | `items`      |
| Partition key | `id` (String)|
| Sort key      | (nenhuma)    |
| Índices (GSI) | (nenhum)     |
| Billing mode  | On-demand (`PAY_PER_REQUEST`) |

```hcl
resource "aws_dynamodb_table" "items" {
  name         = "items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project = "business-platform"
  }
}
```

> A chave de uma tabela DynamoDB é **imutável**. Se `tenant` voltar a ser requisito de isolamento, será necessária tabela nova + migração.

---

## 5. Autorização Cognito (validação do token)

A business API **não cria Cognito**. Ela referencia o User Pool da `auth-platform` e protege cada método com um **Cognito User Pool Authorizer nativo** (sem código, sem Lambda Authorizer), validando assinatura, expiração, emissor e **scope** do access token.

### 5.1 Recursos consumidos da auth-platform

| Item                       | Valor                                   |
|----------------------------|-----------------------------------------|
| User Pool                  | `auth-platform-m2m-user-pool`           |
| Resource server identifier | `m2m-prd`                               |
| Scopes disponíveis         | `m2m-prd/read`, `m2m-prd/write`         |
| Fluxo OAuth                | `client_credentials` (M2M)              |
| TTL do access token        | 30 minutos                              |
| Endpoint de token          | `POST https://minha-api.freeddns.org/oauth/token` |

A referência ao User Pool é feita por **remote state** (mesmo backend S3 da `auth-platform`), evitando hardcode de ARN:

```hcl
data "terraform_remote_state" "auth_platform" {
  backend = "s3"
  config = {
    bucket = "rogerio-iac-prod-us-east-1"
    key    = "rogerio.piardi/terraform/auth-platform/prd.tfstate"
    region = "us-east-1"
  }
}
# usar: data.terraform_remote_state.auth_platform.outputs.user_pool_arn
```

### 5.2 Authorizer + mapa de scopes por método

```hcl
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "business-platform-cognito-authorizer"
  rest_api_id   = aws_api_gateway_rest_api.items.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [data.terraform_remote_state.auth_platform.outputs.user_pool_arn]
  # identity source padrão: method.request.header.Authorization
}
```

| Verbo  | Rota              | Scope exigido   |
|--------|-------------------|-----------------|
| GET    | `/items`          | `m2m-prd/read`  |
| GET    | `/items/{itemId}` | `m2m-prd/read`  |
| POST   | `/items`          | `m2m-prd/write` |
| PUT    | `/items/{itemId}` | `m2m-prd/write` |
| PATCH  | `/items/{itemId}` | `m2m-prd/write` |
| DELETE | `/items/{itemId}` | `m2m-prd/write` |

No método (exemplo GET, leitura):

```hcl
authorization        = "COGNITO_USER_POOLS"
authorizer_id        = aws_api_gateway_authorizer.cognito.id
authorization_scopes = ["m2m-prd/read"]
```

> O access token do `client_credentials` carrega o claim `scope`. O authorizer compara o(s) scope(s) do método com os do token; isso ocorre **na borda**, antes de invocar a Lambda. Um cliente somente-leitura solicita apenas `m2m-prd/read` ao gerar o token.

---

## 6. Validação de contrato no API Gateway (request validation)

O gateway **rejeita requisições malformadas antes de invocar a Lambda**, via **request validator** + **models (JSON Schema)** por método. Em proxy integration o validador roda antes da integração; o corpo **não** é reescrito (a Lambda ainda recebe o body cru).

**Fonte da verdade:** o gateway é primário para **formato** (campos obrigatórios, tipos). A Layer mantém apenas regras semânticas que o JSON Schema não expressa bem (ex.: `description` não vazia após `trim`) — defesa em profundidade, sem duplicação relevante.

**Validator:** validar corpo e parâmetros (`aws_api_gateway_request_validator` com `validate_request_body = true`).

### 6.1 Models (JSON Schema)

POST e PUT — `ItemFull` (ambos os campos obrigatórios, substituição total):

```json
{
  "type": "object",
  "required": ["description", "status"],
  "properties": {
    "description": { "type": "string", "minLength": 1 },
    "status": { "type": "boolean" }
  },
  "additionalProperties": false
}
```

PATCH — `ItemPatch` (parcial, ao menos um campo, sem campos extras):

```json
{
  "type": "object",
  "minProperties": 1,
  "properties": {
    "description": { "type": "string", "minLength": 1 },
    "status": { "type": "boolean" }
  },
  "additionalProperties": false
}
```

GET e DELETE não têm corpo a validar.

---

## 7. Contrato da API

Caminho base no gateway: `/sample-api/v1/items`.

| Verbo  | Rota                | Scope           | Validação body | Operação DynamoDB         | Sucesso | Erros (app)   |
|--------|---------------------|-----------------|----------------|---------------------------|---------|---------------|
| POST   | `/items`            | `m2m-prd/write` | `ItemFull`     | `PutItem`                 | 201     | 400           |
| GET    | `/items`            | `m2m-prd/read`  | —              | `Scan`                    | 200     | —             |
| GET    | `/items/{itemId}`   | `m2m-prd/read`  | —              | `GetItem`                 | 200     | 404           |
| PUT    | `/items/{itemId}`   | `m2m-prd/write` | `ItemFull`     | `PutItem` (upsert)        | 200     | 400           |
| PATCH  | `/items/{itemId}`   | `m2m-prd/write` | `ItemPatch`    | `UpdateItem` (condicional)| 200     | 400, 404      |
| DELETE | `/items/{itemId}`   | `m2m-prd/write` | —              | `DeleteItem`              | 204     | —             |

> Antes desses códigos "de aplicação", o gateway pode retornar **401** (token ausente/inválido/expirado), **403** (scope insuficiente) e **400** (corpo reprovado no validator) — sem invocar a Lambda.

### 7.1 POST `/items` — criar
- Body: `description` + `status` (ambos obrigatórios). Cliente não envia `id`.
- Serviço gera UUID v4 → `PutItem`.
- `201` + item criado; `400` se reprovado na validação semântica residual.

### 7.2 GET `/items` — listar
- `Scan` na tabela, com paginação (`limit` query opcional, cursor `LastEvaluatedKey`).
- `200` + array (possivelmente vazio).
- `Scan` varre a tabela inteira — aceitável em baixo volume; primeira rota a observar se crescer.

### 7.3 GET `/items/{itemId}` — recuperar
- `GetItem` por `id`. `200` + item; `404` se não existir.

### 7.4 PUT `/items/{itemId}` — substituir (upsert)
- Body exige `description` **e** `status` (substituição total).
- `PutItem` direto (upsert): cria se não existir, substitui se existir.
- `200` + item; idempotente.

### 7.5 PATCH `/items/{itemId}` — atualização parcial
- Body: subconjunto de `{ description, status }`; omitidos preservados.
- `UpdateItem` com `SET` nos campos enviados + `ConditionExpression: attribute_exists(id)`.
- `200` + item; `404` se não existir; `400` se nenhum campo válido.

### 7.6 DELETE `/items/{itemId}` — remover
- `DeleteItem` por `id` (idempotente). `204`.
- Opcional: `ConditionExpression: attribute_exists(id)` para `404` em id inexistente. Padrão: idempotente (204).

---

## 8. Contrato de erro

Códigos retornados pela **borda** (antes da Lambda) e pela **aplicação**:

| Situação                                   | HTTP | Origem      | `error`            |
|--------------------------------------------|------|-------------|--------------------|
| Token ausente/inválido/expirado            | 401  | Authorizer  | (gateway)          |
| Scope insuficiente para o método           | 403  | Authorizer  | (gateway)          |
| Corpo reprovado no request validator       | 400  | Validator   | (gateway)          |
| Campo inválido (validação semântica)       | 400  | Lambda      | `ValidationError`  |
| Item inexistente (GET/PATCH)               | 404  | Lambda      | `NotFound`         |
| Falha inesperada                           | 500  | Lambda      | `InternalError`    |

Corpo de erro da aplicação (Lambda):

```json
{ "error": "ValidationError", "message": "..." }
```

> Evolução possível: padronizar também as respostas de erro do gateway (`GatewayResponses`) no mesmo envelope JSON, para o cliente ver um formato único em 401/403/400-de-borda.

---

## 9. Organização do código: Layer × handlers

### 9.1 Lambda Layer (comum)
- **Repositório DynamoDB** (`boto3`): `get_item`, `scan_items`, `put_item`, `update_item`, `delete_item`.
- **Validação (defesa):** `validate_full`, `validate_patch` (regras semânticas além do JSON Schema).
- **Geração de id:** `new_id()` → `str(uuid.uuid4())`.
- **Respostas:** `ok(status, body)`, `error(status, code, message)` no envelope do proxy.
- Inicialização do client DynamoDB no escopo do módulo (reuso entre invocações).

### 9.2 Handlers (Lambda-proxy por verbo)
Funções finas: extraem path/body do evento, chamam validação + repositório da Layer, retornam.

| Função          | Verbo(s)         | Layer                                   |
|-----------------|------------------|-----------------------------------------|
| `items-post`    | POST `/items`    | `validate_full` → `new_id` → `put_item` |
| `items-get`     | GET coleção/item | `get_item` **ou** `scan_items` (por path)|
| `items-put`     | PUT `/items/{}`  | `validate_full` → `put_item`            |
| `items-patch`   | PATCH `/items/{}`| `validate_patch` → `update_item`        |
| `items-delete`  | DELETE `/items/{}`| `delete_item`                          |

> Nomes seguem a convenção `<project>-<resource>` da casa (prefixo de projeto `business-platform-`, sem `aws-`, sem `prd` no nome). Ex.: `business-platform-items-get`.

---

## 10. Permissões IAM (mínimas por função)

Apenas as ações usadas, restritas ao ARN da tabela `items`.

| Função          | Ações DynamoDB                       |
|-----------------|--------------------------------------|
| `items-post`    | `dynamodb:PutItem`                   |
| `items-get`     | `dynamodb:GetItem`, `dynamodb:Scan`  |
| `items-put`     | `dynamodb:PutItem`                   |
| `items-patch`   | `dynamodb:UpdateItem`                |
| `items-delete`  | `dynamodb:DeleteItem`                |

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["dynamodb:GetItem", "dynamodb:Scan"],
    "Resource": "arn:aws:dynamodb:us-east-1:209479281611:table/items"
  }]
}
```

Cada função também precisa de `aws_lambda_permission` (principal `apigateway.amazonaws.com`) para ser invocada pelo gateway. As funções **não** acessam Cognito (a validação é no authorizer nativo) nem Secrets Manager.

---

## 11. Decisões registradas e considerações futuras

**Decisões:**
1. `id` = UUID v4 gerado no POST (DynamoDB não tem auto-geração no banco; app-side é o padrão).
2. PUT = upsert, exige `description` + `status`.
3. PATCH = parcial, exige item existente (404 caso contrário).
4. `status` booleano: `true` ativo / `false` inativo, obrigatório no POST.
5. Sem tenant/partner.
6. Autorização: **Cognito User Pool Authorizer nativo**, scopes `m2m-prd/read` (GET) e `m2m-prd/write` (mutações), consumindo o User Pool da `auth-platform`.
7. Contrato validado no gateway (request validator + models), com defesa residual na Layer.

**Atenção / evolução:**
- **`GET /items` usa `Scan`** — barato agora; mitigar com paginação obrigatória ou GSI se crescer.
- **Scopes só read/write:** granularidade maior (ex.: `items/delete`) exigiria novo scope no resource server da `auth-platform` — fora do escopo desta API.
- **Modelo cresce bem:** novos campos reforçam PUT × PATCH; terceiro estado de `status` pediria enum string no lugar do boolean.
- **Tenant futuro = migração** (chave imutável).
- **Alinhamento de repo:** seguir as convenções do AGENTS.md da `auth-platform` (OpenTofu 1.11.5, GitHub Actions OIDC, backend S3 com `use_lockfile`, Terraform direto vs. OpenAPI import — decidir por consistência com a casa).

---

*Próximo passo sugerido: gerar o esqueleto Terraform da business API (tabela + 5 funções + Layer + authorizer + validators + models + permissions) e o OpenAPI 3.0 atualizado como referência de contrato.*
