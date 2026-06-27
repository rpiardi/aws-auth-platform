# Especificação — Implementação das Abordagens A, C e D (M2M)

| | |
|---|---|
| **Versão** | 1.1 |
| **Data** | 2026-06-22 |
| **Runtime alvo** | Python 3.12 |
| **Escopo** | Propagação de `partner_id` e `tenant` em fluxos M2M, em três abordagens |
| **Store** | env (PARTNERS_JSON), validado no init — comum às três |

---

## 1. Visão geral

As três abordagens entregam ao backend Istio (`.intranet`) os campos estáticos `partner_id` e `tenant` associados ao `client_id`, **via header**, no fluxo M2M (`client_credentials`). Elas compartilham uma base comum (store de parceiros, fail-closed, injeção de header no proxy) e diferem em **onde** a identidade é resolvida e **como** ela chega ao proxy.

| | A · Pre Token Generation (V3) | C · Lambda Authorizer | D · Authorizer nativo + Layer |
|---|---|---|---|
| Onde resolve `client_id → {partner_id, tenant}` | Na emissão do token (trigger V3) | No authorizer (por token, com cache) | Na borda, por request (layer no proxy) |
| Validação do token | Authorizer **nativo** | **Lambda** (JWKS) | Authorizer **nativo** |
| Enforcement de scope | **Nativo** (OpenAPI) | **Reimplementado** no authorizer | **Nativo** (OpenAPI) |
| Como chega ao proxy | `requestContext.authorizer.claims.partner_id` | `requestContext.authorizer.partner_id` | resolvido no proxy via layer |
| Feature plan | Essentials/Plus | Lite+ | Lite+ |

Em todas, os **proxies por verbo** injetam `X-Partner-Id`/`X-Tenant-Id` ao encaminhar ao Istio (a integração `AWS_PROXY` não mapeia claim/context para header automaticamente).

## 2. Fundação comum (todas as abordagens)

### 2.1 Premissas
- API Gateway REST, integração `AWS_PROXY`, um proxy por verbo HTTP.
- Backend Istio com URLs `.intranet`; o proxy faz a chamada de saída.
- Cognito User Pool no fluxo `client_credentials` (M2M).
- O backend só é alcançável através do gateway/proxy.

### 2.2 Store de parceiros (núcleo compartilhado)
Mapa `client_id → {partner_id, tenant}` mantido em `PARTNERS_JSON`, **carregado e validado uma vez no init** (fail-fast): mapa ausente, JSON malformado ou registro sem `partner_id`/`tenant` faz a função falhar no cold start, nunca em runtime. O dado é local (sem rede, sem cache a gerenciar) e a atualização do mapa se dá por redeploy. A mesma lógica de resolução é reutilizada pelas três abordagens — na Lambda de pre-token (A), no authorizer (C) e na layer (D).

### 2.3 Injeção de header no proxy
Comum às três; o proxy, ao montar a chamada de saída ao Istio:
- Remove headers hop-by-hop (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `te`, `trailer`, `proxy-*`), além de `host` e `content-length`.
- Define `X-Partner-Id` e `X-Tenant-Id` com os valores resolvidos, **sobrescrevendo** quaisquer homônimos vindos do cliente (anti-forja).

O que varia entre as abordagens é apenas a **origem do valor** no `event`:

| Abordagem | Origem no event |
|---|---|
| A | `requestContext.authorizer.claims.partner_id` / `.tenant` |
| C | `requestContext.authorizer.partner_id` / `.tenant` |
| D | resolvido no proxy via layer, a partir de `claims.client_id` |

### 2.4 Fail-closed
Parceiro não provisionado ou identidade ausente nunca chega ao backend:
- **A:** a emissão do token falha (nenhum token é emitido).
- **C:** o authorizer retorna 401.
- **D:** a layer rejeita e o proxy responde 403.

## 3. Abordagem A — Pre Token Generation (V3)

### 3.1 Componentes
1. **Lambda Pre Token Generation (V3)** — injeta `partner_id`/`tenant` como claims no access token na emissão.
2. **Authorizer Cognito nativo** — inalterado; valida o token e faz cumprir os scopes (OpenAPI). As claims chegam ao proxy via `requestContext.authorizer.claims`.
3. **Proxies por verbo** — leem as claims e injetam os headers (§2.3).

### 3.2 Configuração do trigger
- User Pool → **Pre token generation** → **Trigger event version V3** (*Basic features + access token customization for user and machine identities*).
- Requer feature plan **Essentials** ou Plus (já em uso).
- A Lambda lê o `client_id` de `callerContext.clientId` (triggerSource `TokenGeneration_ClientCredentials`).
- As claims são adicionadas em `response.claimsAndScopeOverrideDetails.accessTokenGeneration.claimsToAddOrOverride`.
- Env: `PARTNERS_JSON`.

### 3.3 Decisões
- Claims no **access token** (o id token não existe em M2M).
- Limite de ~10.000 caracteres no token — irrelevante para dois campos curtos.
- **Fail-closed:** `client_id` desconhecido faz a emissão do token falhar.
- A resolução roda **na emissão** (~1x/hora por parceiro com cache de token), não por request.

### 3.4 Custo
O custo de **token request M2M** ($0,00225 por token bem-sucedido; sem taxa por app client desde nov/2025) incide no fluxo `client_credentials` — **comum a A, C e D**. A V3 não adiciona custo de Cognito além disso; o trigger é uma invocação Lambda (desprezível) e a customização de access token está inclusa no Essentials.

## 4. Abordagem C — Lambda Authorizer

### 4.1 Componentes
1. **Lambda Authorizer (tipo TOKEN)** — valida o JWT (JWKS), **reimplementa o enforcement de scope** e resolve `partner_id`/`tenant` para o `context`. Identity source: header `Authorization`.
2. **Proxies por verbo** — leem `requestContext.authorizer.partner_id`/`.tenant` e injetam os headers (§2.3).

O authorizer nativo **não** é usado nesta abordagem (é substituído pelo Lambda authorizer).

### 4.2 Validação local (não chamar o Cognito por request)
Validar a assinatura RS256 contra o **JWKS** do pool (cacheado em memória), além de `iss`, `exp` e `token_use=access`. Não há introspection no Cognito e M2M não tem userInfo; a validação é local por performance e disponibilidade.

### 4.3 Reimplementação do scope (o ponto sensível)
O enforcement declarativo do nativo é perdido. O authorizer recebe um mapa **`scope → ["VERB/path", ...]`** e monta o `Resource` da policy IAM com a união dos métodos que os scopes do token permitem.
- **Fonte única:** gerar esse mapa a partir do **contrato OpenAPI** no pipeline (das declarações de `security`/scopes por método), para que o autor continue declarando scope por método como hoje.
- **Cache cross-verbo:** a policy lista todos os métodos que os scopes autorizam (independente do método chamado), então o resultado cacheado por token serve a todos os verbos do mesmo token.

### 4.4 Decisões
- **Fail-closed:** token inválido ou parceiro desconhecido → 401. Token sem scopes correspondentes → policy `Deny` (403).
- `authorizer_result_ttl_in_seconds` > 0 para aproveitar o cache (validação + scope + lookup uma vez por token).
- Env: `AWS_REGION`, `USER_POOL_ID`, `SCOPE_RESOURCE_MAP` (mapa scope→método, gerado do OpenAPI), `PARTNERS_JSON`.

## 5. Abordagem D — Authorizer nativo + Layer

Abordagem **já especificada em detalhe** em:
- `spec-layer-enriquecimento-parceiro.md` (a layer de enriquecimento)
- `spec-proxy-por-verbo.md` (os proxies)

Resumo: o authorizer nativo valida o token e faz cumprir os scopes (OpenAPI). A layer compartilhada resolve `client_id → {partner_id, tenant}` e os proxies injetam os headers. Mantém o Cognito sem customização e resolve a identidade na borda. Reutiliza a mesma lógica de store da §2.2.

## 6. Comparação operacional

| Critério | A | C | D |
|---|---|---|---|
| Componentes novos | Lambda de pre-token | Lambda authorizer | Layer compartilhada |
| Validação do token | Gerenciada (nativo) | Sua responsabilidade | Gerenciada (nativo) |
| Scope | Declarativo (nativo) | Reimplementado (config do OpenAPI) | Declarativo (nativo) |
| Identidade no token | Sim (auditável no JWT) | Não | Não |
| Resolução roda | Na emissão (~1x/h por parceiro) | Por token (com cache) | Por request (env, em memória) |
| Feature plan | Essentials/Plus | Lite+ | Lite+ |

## 7. Próximos passos (Terraform)
- **Comum:** empacotar a lógica de store (módulo nas funções ou layer base); `PARTNERS_JSON` em ponto único (`locals`) consumido por todas as funções.
- **A:** `aws_lambda_function` (pre-token) + configuração do trigger Pre token generation no User Pool com versão de evento **V3**.
- **C:** `aws_lambda_function` (authorizer) + `aws_api_gateway_authorizer` (type `TOKEN`); `SCOPE_RESOURCE_MAP` gerado do OpenAPI no pipeline.
- **D:** ver specs da layer e dos proxies.
- **Proxies (A, C, D):** funções por verbo via `for_each`, com a injeção de header padronizada (§2.3).
