# Especificação — Lambda Layer de Enriquecimento de Identidade de Parceiro (M2M)

| | |
|---|---|
| **Versão** | 1.1 |
| **Data** | 2026-06-03 |
| **Runtime alvo** | Python 3.12 |
| **Tipo de artefato** | AWS Lambda Layer (código compartilhado) |
| **Consumidores** | Lambdas-proxy do API Gateway (uma por verbo HTTP) |
| **Store** | **env (bundled)** — mapa em `PARTNERS_JSON`, sem dependência de rede |

---

## 1. Objetivo

Fornecer uma **camada de código compartilhada** que, dado um request M2M **já autenticado e autorizado**, resolve os dados estáticos do parceiro associados ao `client_id` e devolve os **headers HTTP** que a Lambda-proxy deve injetar ao encaminhar a chamada para o backend (Istio).

A finalidade é **centralizar a lógica de resolução uma única vez**, em vez de replicá-la em cada Lambda-proxy (há uma por verbo HTTP).

## 2. Contexto arquitetural

```
Cliente M2M (client_credentials)
        │  access token (Bearer)
        ▼
API Gateway REST API
        │  ── Authorizer Cognito NATIVO: valida token + faz cumprir scopes
        │     (scopes declarados por método no contrato OpenAPI)
        ▼
Lambda-proxy (uma por verbo, integração AWS_PROXY)
        │  ── chama layer.enrich(claims)
        │  ── mescla headers retornados (sobrescrevendo)
        ▼
Backend Istio (URLs .intranet)
```

Pontos firmados no desenho:

- A **autorização por scope permanece declarativa no OpenAPI** e é feita cumprir pelo **authorizer Cognito nativo** — **não** é responsabilidade desta layer.
- A injeção do header HTTP real ocorre na **Lambda-proxy** (é ela quem monta a chamada de saída ao Istio). A layer apenas **produz** os headers.
- O dado a propagar são **dois campos estáticos por `client_id`**: `partner_id` e `tenant`.

## 3. Escopo

**Dentro do escopo:**
- Extrair `client_id` dos claims.
- Resolver `client_id → {partner_id, tenant}` no mapa local.
- Montar o mapa de headers a injetar.
- Aplicar política de **fail closed**.

**Fora do escopo (de propósito):**
- Validação de token (já feita pelo authorizer nativo).
- Verificação de scope / autorização (idem).
- Montagem/execução da chamada HTTP ao Istio (responsabilidade do proxy).
- Lógica de negócio.

## 4. Contrato (interface pública)

### Ponto de entrada

```
enrich(claims: dict | None) -> EnrichmentResult
```

- **Entrada:** o objeto de claims, obtido pelo proxy em
  `event["requestContext"]["authorizer"]["claims"]`.
  O proxy entrega **os claims**, não o event inteiro nem apenas o `client_id`.
- **Saída:** um `EnrichmentResult`.

### Tipo de resultado

| Campo | Tipo | Descrição |
|---|---|---|
| `ok` | `bool` | `True` = sucesso; `False` = rejeição |
| `headers` | `dict \| None` | Em sucesso: **mapa opaco** de headers a mesclar |
| `reason` | `str \| None` | Em rejeição: motivo (ver §6) |

**Regra de saída opaca:** em sucesso, a layer devolve um **mapa de headers já prontos**, não campos nomeados. O proxy trata o retorno como mapa genérico a mesclar. Consequência: **acrescentar um novo campo no futuro é mudança apenas na layer** (§5, RF5) — os proxies não mudam.

## 5. Requisitos funcionais

| ID | Requisito |
|---|---|
| RF1 | Extrair o `client_id` dos claims, usando o nome de claim configurável (`CLIENT_ID_CLAIM`, default `client_id`). |
| RF2 | Resolver `{partner_id, tenant}` pelo `client_id` no mapa local. |
| RF3 | Montar mapa de headers: `partner_id → X-Partner-Id`, `tenant → X-Tenant-Id` (nomes configuráveis). |
| RF4 | Devolver `EnrichmentResult.success(headers)` ou `EnrichmentResult.reject(reason)`. |
| RF5 | A inclusão de um novo campo deve exigir alteração **apenas** na função de montagem de headers — sem impacto nos proxies. |
| RF6 | Carregar e **validar** o mapa no init (cold start). Mapa ausente, JSON malformado ou registro sem `partner_id`/`tenant` deve **falhar no init** (fail-fast), nunca em runtime. |

## 6. Regras de decisão — FAIL CLOSED

Postura padrão: **fail closed**. Nenhuma das situações abaixo encaminha ao backend sem contexto de tenant.

| `reason` | Causa | Status HTTP sugerido no proxy |
|---|---|---|
| `missing_claims` | Objeto de claims ausente/vazio | 403 |
| `missing_client_id` | Claim de `client_id` ausente nos claims | 403 |
| `unknown_client` | `client_id` não encontrado no mapa (parceiro não provisionado) | 403 |

> Erros de configuração do mapa (ausente/malformado/incompleto) **não** são casos de runtime: falham no init (RF6), antes de servir qualquer tráfego.

## 7. Configuração (variáveis de ambiente)

| Variável | Obrigatória | Default | Descrição |
|---|---|---|---|
| `PARTNERS_JSON` | **Sim** | — | Mapa JSON `{client_id: {partner_id, tenant}}` |
| `CLIENT_ID_CLAIM` | Não | `client_id` | Nome do claim que carrega o `client_id` |
| `HEADER_PARTNER_ID` | Não | `X-Partner-Id` | Nome do header de saída para `partner_id` |
| `HEADER_TENANT` | Não | `X-Tenant-Id` | Nome do header de saída para `tenant` |
| `LOG_LEVEL` | Não | `INFO` | Nível de log |

Exemplo de `PARTNERS_JSON`:

```json
{
  "1example23clientid": { "partner_id": "PARTNER-001", "tenant": "acme" },
  "4example56clientid": { "partner_id": "PARTNER-002", "tenant": "globex" }
}
```

## 8. Store de dados — env (bundled)

- O mapa é parseado e **validado uma única vez no init** a partir de `PARTNERS_JSON`.
- O dado é **local**: não há chamada de rede em runtime, não há modo de falha de carga em runtime, não há cache a gerenciar.
- **Atualização do mapa = redeploy** (nova versão da layer + atualização dos proxies que a referenciam).
- Adequado a um conjunto **pequeno e estático** de parceiros com onboarding pouco frequente.

## 9. Requisitos não-funcionais

| ID | Requisito |
|---|---|
| RNF1 | Sem store remoto e sem cache: mapa carregado/validado no init (dado local). |
| RNF2 | Sem validação de token e sem lógica de scope/autorização. |
| RNF3 | Sem estado próprio; resultado determinístico dado o mesmo `PARTNERS_JSON`. |
| RNF4 | Observabilidade: logar cada motivo de rejeição; recomendado métrica para `unknown_client`. |
| RNF5 | Runtime Python 3.12. |
| RNF6 | **Sem dependências externas** (apenas biblioteca padrão). |
| RNF7 | Testável isoladamente. |

## 10. Segurança

- **Anti-forja de header:** o proxy deve **sobrescrever** qualquer `X-Partner-Id` / `X-Tenant-Id` enviado pelo cliente com os valores retornados pela layer (ordem de merge: cliente primeiro, layer por último).
- **Fronteira de confiança:** `requestContext.authorizer.claims` é populado **somente** pelo API Gateway; o cliente não consegue forjá-lo.
- **Fail closed:** garante que nenhum request chegue ao Istio sem `tenant` resolvido.
- **Pré-condição de rede:** o backend Istio não deve ser alcançável fora do API Gateway/proxy (caso contrário o header injetado deixa de ser fonte de verdade).

## 11. Integração com os proxies (contrato de consumo)

Comportamento esperado de cada Lambda-proxy:

1. Obter os claims de `event["requestContext"]["authorizer"]["claims"]`.
2. Chamar `enrich(claims)`.
3. Se `result.ok` for `False`: responder **403** **sem** chamar o Istio.
4. Se `result.ok` for `True`: mesclar `result.headers` nos headers de saída (**sobrescrevendo** os do cliente) e encaminhar ao Istio.

O footprint por proxy resume-se a esses 4 passos.

## 12. Empacotamento (Lambda Layer)

- Estrutura para importação direta como `from partner_enrichment import enrich`:

```
layer/
└── python/
    └── partner_enrichment.py
```

- **Compatible runtimes:** `python3.12`.
- Sem dependências empacotadas (RNF6).
- **Versionamento:** versões de layer são imutáveis. Referenciar a versão por um único `locals`/variável no Terraform, consumido por todas as definições de proxy, para que o bump seja uma mudança em ponto único.

## 13. Testes (unitários)

| Caso | Resultado esperado |
|---|---|
| Claims válidos, parceiro existente | `ok=True`, headers com `X-Partner-Id` e `X-Tenant-Id` |
| Claims ausentes/vazios | `ok=False`, `reason=missing_claims` |
| Claims sem `client_id` | `ok=False`, `reason=missing_client_id` |
| `client_id` não provisionado | `ok=False`, `reason=unknown_client` |
| `PARTNERS_JSON` ausente/malformado/incompleto | Falha no **init** (não é caso de runtime) |

## 14. Fora de escopo / evolução futura

- **Cache / store remoto (ex.: DynamoDB):** introdução posterior como **mudança interna à layer** (substituir a carga do mapa), sem impacto no contrato nem nos proxies. Gatilho: necessidade de atualizar o mapa sem redeploy ou crescimento do conjunto de parceiros.
- **Autorização fine-grained:** permanece no authorizer nativo via scopes declarados no OpenAPI; não migra para esta layer.

---

## Apêndice A — Implementação de referência

```python
"""
Camada de enriquecimento de identidade de parceiro (M2M) — Perfil env.
Ver especificação seções 4–10.

Responsabilidade ÚNICA: dado o objeto de claims que o API Gateway entrega
(populado pelo authorizer Cognito nativo), resolver os dados estáticos do
parceiro associados ao client_id e devolver os headers que o proxy deve
injetar na chamada de saída ao Istio.

NÃO faz: validação de token, verificação de scope, autorização.
Falha: FAIL CLOSED. Config inválida falha no init (fail-fast).
"""
import json
import logging
import os
from dataclasses import dataclass

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CLIENT_ID_CLAIM   = os.environ.get("CLIENT_ID_CLAIM", "client_id")
HEADER_PARTNER_ID = os.environ.get("HEADER_PARTNER_ID", "X-Partner-Id")
HEADER_TENANT     = os.environ.get("HEADER_TENANT", "X-Tenant-Id")


def _load_partners() -> dict:
    """
    Carrega e VALIDA o mapa no init. Falha rápido (cold start) se PARTNERS_JSON
    estiver ausente, malformado ou com registros incompletos — configuração
    inválida nunca serve tráfego (RF6).
    """
    raw = os.environ["PARTNERS_JSON"]          # KeyError se ausente -> falha no init
    partners = json.loads(raw)                 # JSONDecodeError se malformado -> idem
    for client_id, record in partners.items():
        if "partner_id" not in record or "tenant" not in record:
            raise ValueError(f"Registro incompleto para client_id={client_id}")
    return partners


# Carregado e validado uma vez no init; dado local, sem store em runtime.
_PARTNERS = _load_partners()


@dataclass(frozen=True)
class EnrichmentResult:
    ok: bool
    headers: dict | None = None
    reason: str | None = None

    @staticmethod
    def success(headers: dict) -> "EnrichmentResult":
        return EnrichmentResult(ok=True, headers=headers)

    @staticmethod
    def reject(reason: str) -> "EnrichmentResult":
        return EnrichmentResult(ok=False, reason=reason)


def _build_headers(record: dict) -> dict:
    # Único ponto a alterar para acrescentar um novo campo (RF5).
    return {
        HEADER_PARTNER_ID: str(record["partner_id"]),
        HEADER_TENANT:     str(record["tenant"]),
    }


def enrich(claims: dict | None) -> EnrichmentResult:
    if not claims:
        logger.warning("Claims ausentes")
        return EnrichmentResult.reject("missing_claims")

    client_id = claims.get(CLIENT_ID_CLAIM)
    if not client_id:
        logger.warning("client_id ausente nos claims")
        return EnrichmentResult.reject("missing_client_id")

    record = _PARTNERS.get(client_id)
    if record is None:
        logger.warning("Parceiro desconhecido (client_id=%s)", client_id)
        return EnrichmentResult.reject("unknown_client")

    return EnrichmentResult.success(_build_headers(record))
```

## Apêndice B — Consumo pelo proxy (não-normativo)

```python
from partner_enrichment import enrich

def handler(event, context):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("claims")
    result = enrich(claims)

    if not result.ok:
        return {"statusCode": 403, "body": "{}"}

    # cliente primeiro, layer por último (sobrescreve — anti-forja)
    outbound = {**incoming_headers, **result.headers}
    # ... encaminha ao Istio com `outbound` ...
```
