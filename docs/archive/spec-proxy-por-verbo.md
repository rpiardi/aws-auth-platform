# Especificação — Lambdas-proxy por verbo (M2M)

| | |
|---|---|
| **Versão** | 1.0 |
| **Data** | 2026-06-03 |
| **Runtime alvo** | Python 3.12 |
| **Integração API Gateway** | REST API, `AWS_PROXY` |
| **Depende de** | Layer de Enriquecimento de Parceiro v1.1 (Perfil env) |

---

## 1. Objetivo

Especificar as funções Lambda que atuam como **proxy** entre o API Gateway e o backend Istio (URLs `.intranet`), encaminhando o request e injetando os headers de identidade do parceiro produzidos pela **layer de enriquecimento**.

## 2. Princípio central — comportamento único, instanciado por verbo

O código de proxy é **idêntico para todos os verbos**. O verbo é **dado** (`event["httpMethod"]`), não código.

Portanto, **não** se especificam N funções distintas: especifica-se **um comportamento de proxy** (fonte única) e o instancia por verbo (GET, POST, PUT, DELETE, PATCH...) via **`for_each` no Terraform**. Cada instância difere apenas em **configuração de deploy**, não em lógica.

Razão de existir o split por verbo: **isolamento operacional** — concorrência, throttling, métricas e blast radius por verbo. Se esse isolamento não for necessário, a alternativa é uma única função em método `ANY` (fora do escopo desta spec, que assume o split já adotado).

## 3. Relação com a layer

- O proxy importa `enrich` da layer: `from partner_enrichment import enrich`.
- Como a layer lê `PARTNERS_JSON` do ambiente **da função**, **cada função-proxy deve carregar `PARTNERS_JSON`** (e as demais variáveis da layer) no seu próprio env.
- Consequência operacional: alterar o mapa de parceiros = atualizar o env de **todas** as funções-proxy. Gerenciar via **ponto único** no Terraform (`locals`/variável) consumido por todas (mesmo padrão da referência de versão da layer).

## 4. Contrato de entrada/saída

- **Entrada:** event de proxy do API Gateway (`AWS_PROXY`), contendo `httpMethod`, `path`, `queryStringParameters`, `headers`, `body`, `isBase64Encoded` e `requestContext.authorizer.claims`.
- **Saída:** resposta no formato proxy — `{ statusCode, headers, body, isBase64Encoded }`.

## 5. Fluxo funcional

1. Extrair claims de `event["requestContext"]["authorizer"]["claims"]`.
2. Chamar `enrich(claims)`.
3. Se `result.ok` for `False` → responder **403** **sem** chamar o backend.
4. Se `result.ok` for `True`:
   1. Construir a URL de saída (§6).
   2. Construir os headers de saída (§6) mesclando os do cliente com os da layer (layer **sobrescreve**).
   3. Encaminhar ao backend com o método de `event["httpMethod"]`.
   4. Mapear a resposta do backend para o formato proxy (§7).

## 6. Construção do request de saída

| Elemento | Regra |
|---|---|
| **Método** | `event["httpMethod"]`. |
| **URL** | `BACKEND_BASE_URL` + `event["path"]` + query string (`queryStringParameters`). |
| **Headers** | Headers de entrada **menos** hop-by-hop (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `te`, `trailer`, `proxy-*`), `host` e `content-length`; em seguida **mesclar os headers da layer por último** (sobrescrevem — anti-forja). |
| **Body** | `event["body"]`, decodificando de base64 se `isBase64Encoded` for `True`. |

> **Decisão a confirmar:** encaminhar ou não o header `Authorization` (token original) ao Istio. Como os scopes já são feitos cumprir no authorizer nativo, o backend normalmente **não** precisa do token. Recomenda-se **não** encaminhar, salvo se o mesh fizer validação própria.

## 7. Mapeamento da resposta do backend

- `statusCode` ← status HTTP do backend (inclusive erros HTTP, que são repassados).
- `headers` ← headers do backend (remover hop-by-hop conforme necessário).
- `body` ← corpo; se binário, `isBase64Encoded = True` e corpo em base64.

## 8. Tratamento de erros de backend

| Situação | Resposta |
|---|---|
| Backend respondeu erro HTTP (4xx/5xx) | Repassar status e corpo do backend |
| Falha de conexão / DNS | **502** |
| Timeout | **504** |

## 9. Configuração (por função)

| Variável | Obrigatória | Default | Descrição |
|---|---|---|---|
| `BACKEND_BASE_URL` | **Sim** | — | Base `.intranet` do backend (ex.: `https://svc.intranet`) |
| `BACKEND_TIMEOUT_SECONDS` | Não | `25` | Timeout da chamada ao backend (< 29s do API Gateway) |
| `PARTNERS_JSON` | **Sim** | — | Mapa de parceiros (consumido pela layer) |
| `CLIENT_ID_CLAIM` / `HEADER_PARTNER_ID` / `HEADER_TENANT` / `LOG_LEVEL` | Não | (ver spec da layer) | Configuração da layer |

Outras propriedades da função:

- **Layers:** a layer de enriquecimento (referência de versão em ponto único).
- **VPC:** subnets + security group com rota/resolução para o domínio `.intranet` (Route53 private hosted zone ou resolver on-prem).
- **Timeout da função:** ≥ `BACKEND_TIMEOUT_SECONDS`, mas alinhado ao teto de 29s do API Gateway.
- **Memória/concorrência:** ajustável **por verbo** (ex.: POST/PUT com payloads maiores).

## 10. Requisitos não-funcionais

| ID | Requisito |
|---|---|
| RNF1 | VPC-attached com DNS para `.intranet`. |
| RNF2 | **IAM mínimo:** apenas `AWSLambdaVPCAccessExecutionRole` (ENIs) + logs. **Sem** permissões de DynamoDB/SSM — o Perfil env não acessa store remoto. |
| RNF3 | **Sem NAT/VPC endpoints exigidos pelo enriquecimento** — a única saída de rede necessária é para o backend `.intranet`. |
| RNF4 | Runtime Python 3.12; sem dependências externas no caminho-base (urllib da stdlib). |
| RNF5 | Cold start: avaliar provisioned concurrency apenas em verbos sensíveis à latência. |

## 11. Matriz de instâncias (deploy por verbo)

Uma fonte, N funções via `for_each` sobre a lista de verbos. Sugestão de config por instância:

| Verbo | Memória sugerida | Concorrência reservada |
|---|---|---|
| GET | 256 MB | conforme tráfego |
| POST | 512 MB | conforme tráfego |
| PUT | 512 MB | conforme tráfego |
| DELETE | 256 MB | conforme tráfego |
| PATCH | 512 MB | conforme tráfego |

Nome sugerido: `proxy-<verbo>-<api>` (ex.: `proxy-get-gamification`).

## 12. Segurança

- **Anti-forja de header:** os headers da layer sobrescrevem quaisquer homônimos vindos do cliente (ordem de merge garante isso).
- **Least privilege:** execution role sem acesso a dados (RNF2).
- **Token ao backend:** ver decisão na §6 (recomendado não encaminhar).
- **Pré-condição:** backend não alcançável fora do API Gateway/proxy.

## 13. Testes

| Caso | Esperado |
|---|---|
| Parceiro válido | Forward ao backend; `X-Partner-Id`/`X-Tenant-Id` injetados; status do backend repassado |
| `X-Partner-Id` forjado pelo cliente | Sobrescrito pelo valor da layer |
| Hop-by-hop/host de entrada | Removidos no request de saída |
| Cliente desconhecido / claims inválidos | **403**, backend não é chamado |
| Backend indisponível | **502** |
| Timeout do backend | **504** |

---

## Apêndice A — Implementação de referência (não-normativa)

```python
"""
Lambda-proxy por verbo (M2M) — encaminha ao backend Istio com enriquecimento.
Fonte ÚNICA: implantada como N funções (uma por verbo) via Terraform for_each.
O verbo vem do event (event["httpMethod"]).
"""
import base64
import logging
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode

from partner_enrichment import enrich  # fornecido pela layer de enriquecimento

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

BACKEND_BASE_URL = os.environ["BACKEND_BASE_URL"].rstrip("/")
BACKEND_TIMEOUT  = float(os.environ.get("BACKEND_TIMEOUT_SECONDS", "25"))

_HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
}


def _build_outbound_headers(event, enrichment_headers):
    incoming = event.get("headers") or {}
    headers = {k: v for k, v in incoming.items() if k.lower() not in _HOP_BY_HOP}
    headers.update(enrichment_headers)  # layer por último: sobrescreve (anti-forja)
    return headers


def _build_url(event):
    url = f"{BACKEND_BASE_URL}{event.get('path', '/')}"
    qs = event.get("queryStringParameters") or {}
    return f"{url}?{urlencode(qs)}" if qs else url


def _decode_body(event):
    body = event.get("body")
    if body is None:
        return None
    return base64.b64decode(body) if event.get("isBase64Encoded") else body.encode("utf-8")


def _proxy_response(status, headers, body_bytes):
    try:
        body, is_b64 = body_bytes.decode("utf-8"), False
    except (UnicodeDecodeError, AttributeError):
        body, is_b64 = base64.b64encode(body_bytes or b"").decode("ascii"), True
    return {"statusCode": status, "headers": headers, "body": body, "isBase64Encoded": is_b64}


def handler(event, context):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("claims")
    result = enrich(claims)
    if not result.ok:
        logger.warning("Enriquecimento rejeitado: %s", result.reason)
        return {"statusCode": 403, "body": "{}"}

    req = urllib.request.Request(
        url=_build_url(event),
        data=_decode_body(event),
        headers=_build_outbound_headers(event, result.headers),
        method=event["httpMethod"],
    )
    try:
        with urllib.request.urlopen(req, timeout=BACKEND_TIMEOUT) as resp:
            return _proxy_response(resp.status, dict(resp.headers), resp.read())
    except urllib.error.HTTPError as e:
        return _proxy_response(e.code, dict(e.headers), e.read())
    except urllib.error.URLError as e:
        logger.error("Falha ao alcançar o backend: %s", e)
        return {"statusCode": 502, "body": "{}"}
    except TimeoutError:
        logger.error("Timeout ao alcançar o backend")
        return {"statusCode": 504, "body": "{}"}
```

> **Endurecimento para produção (fora da referência):** pool de conexões e retries (ex.: `urllib3`/`requests` via layer dedicada), tratamento de `multiValueHeaders`/`multiValueQueryStringParameters`, detecção de binário por `Content-Type`, e verificação TLS contra a CA interna do `.intranet`.
