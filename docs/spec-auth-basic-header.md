# Especificação — Autenticação via Header Authorization (Basic Auth)

| | |
|---|---|
| **Versão** | 1.0 |
| **Data** | 2026-06-27 |
| **Componentes** | API Gateway REST, Lambda Wrapper, Cognito User Pool |
| **Modo de Integração** | REST API, `AWS_PROXY` |

---

## 1. Objetivo

Especificar as modificações necessárias para migrar o envio das credenciais de cliente (`client_id` e `client_secret`) do corpo da requisição (`application/x-www-form-urlencoded`) para o cabeçalho HTTP `Authorization` no formato **Basic Auth** (Basic Access Authentication), contendo as credenciais concatenadas e codificadas em Base64 (`client_id:client_secret`).

Adicionalmente, esta especificação define a validação do contrato na camada do API Gateway para garantir que requisições sem o cabeçalho `Authorization` sejam rejeitadas antes mesmo de invocarem a função Lambda Wrapper.

---

## 2. Fluxo da Requisição

```text
Consumidor
   │
   │ POST /oauth/token
   │ Header: Authorization: Basic <base64(client_id:client_secret)>
   │ Body: grant_type=client_credentials&scope=m2m-prd/read
   ▼
API Gateway REST (auth-platform-api)
   │
   ├─► [Validação de Contrato] (Verifica presença do Header Authorization)
   │     ├─► [Ausente] ──► Retorna 400 Bad Request (API Gateway)
   │     └─► [Presente] ──┐
   ▼                      ▼
Lambda Wrapper (auth-platform-lambda-wrapper)
   │
   ├─► Extrai o header Authorization (case-insensitive)
   ├─► Repassa o header e o body para a URL de Token do Cognito
   ▼
Cognito /oauth2/token
   │
   ├─► Valida as credenciais em Base64 e o grant_type
   └─► Retorna resposta (Token ou Erro)
```

---

## 3. Alterações no API Gateway (Terraform)

As alterações serão feitas no arquivo [`apigateway.tf`](file:///home/ubuntu/projects/awscli/aws-auth-platform/terraform/apigateway.tf).

### 3.1. Novo Recurso: Validador de Requisição
Deve ser criado um recurso de validação de parâmetros de requisição (`aws_api_gateway_request_validator`) no Terraform para validar a presença de headers.

```hcl
resource "aws_api_gateway_request_validator" "auth_validator" {
  name                        = "${var.project_name}-validator"
  rest_api_id                 = aws_api_gateway_rest_api.auth.id
  validate_request_parameters = true
  validate_request_body       = false
}
```

### 3.2. Atualização do Método POST `/token`
O recurso `aws_api_gateway_method.token_post` deve ser alterado para vincular o validador acima e declarar o cabeçalho `Authorization` como obrigatório (`required = true` mapeado no dicionário `request_parameters`).

```hcl
resource "aws_api_gateway_method" "token_post" {
  rest_api_id   = aws_api_gateway_rest_api.auth.id
  resource_id   = aws_api_gateway_resource.token.id
  http_method   = "POST"
  authorization = "NONE"

  request_validator_id = aws_api_gateway_request_validator.auth_validator.id
  request_parameters = {
    "method.request.header.Authorization" = true
  }
}
```

---

## 4. Alterações na Lambda Wrapper

As alterações ocorrem no arquivo [`lambda_function.py`](file:///home/ubuntu/projects/awscli/aws-auth-platform/src/wrapper/lambda_function.py).

### 4.1. Obtenção Case-Insensitive do Cabeçalho `Authorization`
A Lambda deve buscar o cabeçalho no dicionário `event.get("headers")` lidando com possíveis variações de caixa (ex: `Authorization` ou `authorization`).

```python
def _get_authorization_header(event):
    headers = event.get("headers") or {}
    for key, value in headers.items():
        if key.lower() == "authorization":
            return value
    return None
```

### 4.2. Repasse do Header ao Cognito
No método principal `lambda_handler`, ao construir a requisição HTTP para o Cognito, caso o header `Authorization` esteja presente, ele deve ser repassado.

```python
    auth_header = _get_authorization_header(event)
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
    }
    if auth_header:
        headers["Authorization"] = auth_header

    request = urllib.request.Request(
        cognito_token_url,
        data=request_body,
        headers=headers,
        method="POST",
    )
```

### 4.3. Restrições de Log (Segurança)
Para cumprir as regras de conformidade de segurança e não expor segredos nos logs do CloudWatch:
- O cabeçalho `Authorization` **nunca** deve ser impresso no log da Lambda em formato texto limpo ou em dumps de depuração.

---

## 5. Matriz de Casos de Teste e Validação

| Cenário de Teste | Entrada Esperada | Comportamento Esperado | Resultado HTTP | Responsável pela Validação |
|---|---|---|---|---|
| **Sem Header Authorization** | Body: `grant_type=client_credentials` | Rejeitado sumariamente sem acionar a Lambda. | `400 Bad Request` | API Gateway |
| **Com Header Vazio ou Malformado** | Header: `Authorization: Basic` / `Authorization: Malformed` | Repassado para o Cognito. Cognito nega o token. | `401 Unauthorized` / `400 Bad Request` | Cognito |
| **Com Header Válido e Credenciais Corretas** | Header: `Authorization: Basic <base64>` | Autenticação bem-sucedida, Cognito gera e retorna o JWT. | `200 OK` | Cognito |
| **Método HTTP incorreto (ex: GET)** | Path: `/token`, Método: `GET` | Rejeitado pela Lambda ou API Gateway (dependendo do roteamento). | `405 Method Not Allowed` / `403 Forbidden` | API Gateway / Lambda |

---

## 6. Referências de Requisição (Exemplo)

### Formato do Header `Authorization`
Para um `client_id` igual a `my-client-id` e `client_secret` igual a `my-client-secret`:
1. Concatenar: `my-client-id:my-client-secret`
2. Codificar em Base64: `bXktY2xpZW50LWlkOm15LWNsaWVudC1zZWNyZXQ=`
3. Cabeçalho final: `Authorization: Basic bXktY2xpZW50LWlkOm15LWNsaWVudC1zZWNyZXQ=`

### Exemplo de Requisição via `curl`
```bash
curl -X POST "https://minha-api.freeddns.org/oauth/token" \
  -H "Authorization: Basic bXktY2xpZW50LWlkOm15LWNsaWVudC1zZWNyZXQ=" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&scope=m2m-prd/read"
```
