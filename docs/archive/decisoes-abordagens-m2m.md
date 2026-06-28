# Decisões — Abordagens M2M A, C e D

Este documento consolida as decisões discutidas sobre as propostas A, C e D
para propagação de `partner_id` e `tenant` em fluxos M2M.

## Contexto atual

O projeto atual implementa apenas o endpoint de autenticação:

```text
Consumer
  -> API Gateway
  -> Lambda wrapper
  -> Cognito /oauth2/token
  -> JWT access token
```

As propostas A, C e D adicionam uma segunda responsabilidade: usar o token M2M
para proteger chamadas a backends internos e propagar identidade de parceiro
por headers.

Antes de implementar qualquer proposta, é necessário decidir formalmente se este
repositório continuará sendo apenas `auth-platform` ou se passará a incluir
também componentes de proxy/API gateway para backends internos.

## Decisão comum

O mapeamento necessário é:

```text
client_id -> partner_id, tenant
```

`client_id` é o ID real do Cognito App Client, não o nome amigável do cliente.

Para cadastro frequente de parceiros, não é recomendado manter esse mapa apenas
em variável de ambiente `PARTNERS_JSON`, porque cada alteração exigiria update
de configuração/redeploy da Lambda.

Stores considerados:

| Store | Avaliação |
|---|---|
| `PARTNERS_JSON` em env var | Simples, mas exige redeploy para qualquer alteração. Adequado apenas para poucos parceiros e baixa frequência de mudança. |
| SSM Parameter Store com JSON único | Viável tecnicamente, mas frágil para cadastro frequente: regrava tudo, risco de concorrência, limite de tamanho e sem lookup natural por `client_id`. |
| SSM Parameter Store com um parâmetro por parceiro | Viável para volume baixo/moderado. Exemplo: `/auth-platform/partners/<client_id>`. |
| DynamoDB | Recomendado para cadastro frequente, lookup direto por `client_id`, evolução para admin/API e melhor perfil para alto volume. |

Para uma solução robusta, a recomendação é DynamoDB:

```text
PK: client_id
partner_id
tenant
status
updated_at
```

## Proposta A — Pre Token Generation V3

### Funcionamento

```text
Cognito /oauth2/token
  -> Lambda Pre Token Generation V3
  -> resolve client_id
  -> injeta partner_id/tenant no access token
```

Depois, nas chamadas de API:

```text
API Gateway
  -> Cognito Authorizer nativo
  -> valida token e scopes
  -> Lambda proxy lê claims
  -> injeta headers ao backend
```

### Decisões

- A proposta A mantém o Cognito Authorizer nativo.
- A Lambda de Pre Token não substitui o authorizer; ela apenas customiza o token
  antes da emissão.
- `partner_id` e `tenant` passam a fazer parte do access token.
- A resolução ocorre na emissão do token, não por request.
- Tokens já emitidos continuam com claims antigas até expirarem.
- Se o parceiro for desconhecido ou inativo, a Lambda deve falhar fechado e o
  Cognito não deve emitir o token.

### Pré-requisitos

- User Pool em feature plan compatível com Pre Token Generation `V3_0`
  para machine identities.
- App Client usando `client_credentials`.
- Lambda configurada como Pre Token Generation com `LambdaVersion = "V3_0"`.
- Permissão para Cognito invocar a Lambda.
- Store de parceiros acessível pela Lambda.
- Lambda deve ler:

```python
event["callerContext"]["clientId"]
```

- Lambda deve adicionar claims em:

```python
event["response"]["claimsAndScopeOverrideDetails"] = {
    "accessTokenGeneration": {
        "claimsToAddOrOverride": {
            "partner_id": "...",
            "tenant": "..."
        }
    }
}
```

### Store recomendada para A

Para cadastro frequente, DynamoDB é a opção preferida. SSM por parceiro também é
viável em volumes menores.

Como a Lambda roda na emissão do token, e não em toda chamada de API, o volume de
lookup tende a ser menor do que na proposta D.

## Proposta C — Lambda Authorizer

### Funcionamento

```text
API Gateway
  -> Lambda Authorizer TOKEN
  -> valida JWT
  -> valida scopes
  -> resolve partner_id/tenant
  -> retorna IAM policy + context
  -> Lambda proxy injeta headers
```

### Decisões

- A proposta C substitui o Cognito Authorizer nativo.
- A validação do token passa a ser responsabilidade da Lambda Authorizer.
- O enforcement de scopes também passa a ser responsabilidade da Lambda
  Authorizer.
- O authorizer deve retornar `partner_id` e `tenant` no `context`.
- A Lambda proxy deve ler:

```python
event["requestContext"]["authorizer"]["partner_id"]
event["requestContext"]["authorizer"]["tenant"]
```

### Pré-requisitos

- Lambda Authorizer tipo `TOKEN`.
- Parsing seguro de `Authorization: Bearer <jwt>`.
- Validação de JWT RS256 com JWKS do Cognito.
- Validação de `iss`, `exp`, `token_use=access` e `client_id`.
- Store de parceiros.
- Mapa de escopos para métodos/API resources.
- Geração correta de policy IAM para `execute-api:Invoke`.
- Configuração cuidadosa de cache do authorizer.

### Riscos

Esta é a proposta mais complexa e com maior risco operacional:

- reimplementa validação JWT;
- reimplementa autorização por scope;
- precisa lidar com cache de JWKS;
- precisa gerar policies corretas;
- tende a exigir dependência externa para validação JWT/cripto, como PyJWT com
  suporte a criptografia.

Só deve ser escolhida se houver uma limitação concreta que impeça o uso do
Cognito Authorizer nativo.

## Proposta D — Cognito Authorizer nativo + Layer

### Funcionamento

```text
Cliente M2M
  -> API Gateway REST
  -> Cognito Authorizer nativo valida token e scopes
  -> Lambda proxy por verbo
  -> Layer resolve client_id
  -> Proxy injeta X-Partner-Id / X-Tenant-Id
  -> Backend Istio
```

### Decisões

- A proposta D mantém o Cognito Authorizer nativo.
- O token não precisa carregar `partner_id` nem `tenant`.
- A resolução ocorre por request, dentro da Lambda proxy/layer.
- A layer não valida token nem scopes; ela confia nos claims populados pelo
  Cognito Authorizer nativo.
- Se claims estiverem ausentes, `client_id` estiver ausente ou o parceiro for
  desconhecido, a resposta deve ser `403` e o backend não deve ser chamado.

### Componentes necessários

- Cognito Authorizer nativo nos métodos protegidos.
- Lambda Layer `partner_enrichment`.
- Lambdas proxy por verbo, com uma fonte única de código e instâncias via
  `for_each`.
- Store de parceiros.
- VPC config nas Lambdas proxy para alcançar o backend `.intranet`.
- Sanitização de headers hop-by-hop.
- Injeção anti-forja:

```text
X-Partner-Id
X-Tenant-Id
```

### Store recomendada para D

Como a resolução ocorre por request, DynamoDB é a opção preferida para cadastro
frequente e volume relevante.

SSM por parceiro é viável em cenários menores, mas pode se tornar gargalo ou
fonte de throttling dependendo do volume de requests.

Cache em memória com TTL curto pode ser usado para reduzir custo/latência:

```text
client_id -> partner record
TTL: 30s, 60s ou 300s
```

O cache deve preservar a postura fail-closed em caso de erro.

## Comparação resumida

| Critério | A | C | D |
|---|---|---|---|
| Mantém Cognito Authorizer nativo | Sim | Não | Sim |
| Onde resolve parceiro | Emissão do token | Authorizer | Proxy/layer |
| Claims no JWT | Sim | Não | Não |
| Scope enforcement | Nativo | Reimplementado | Nativo |
| Impacto de mudança no cadastro | Tokens novos | Próxima autorização, considerando cache | Próximo request, considerando cache |
| Complexidade | Média | Alta | Média |
| Melhor para cadastro frequente | Boa com DynamoDB/SSM, mas tokens antigos expiram depois | Possível, mas complexa | Boa com DynamoDB/cache |

## Recomendação atual

- Evitar C salvo necessidade concreta.
- Para preservar Cognito Authorizer nativo, escolher entre A e D.
- Escolher A se for aceitável carregar `partner_id`/`tenant` no access token e
  esperar a expiração do token para refletir alterações.
- Escolher D se for importante manter o token limpo e refletir mudanças de
  parceiro mais rapidamente nas chamadas de API.
- Para cadastro frequente, preferir DynamoDB como store de parceiros.
