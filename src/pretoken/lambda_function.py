"""Pre Token Generation V3 trigger (Approach A).

Resolves the calling M2M client_id to a partner identity (partner_id, tenant)
at access-token issuance time and injects it as signed claims. Unknown or
invalid clients fail closed: the trigger raises and Cognito does not issue a
token.

Never logs tokens, secrets, the Authorization header, or the raw token request.
"""

import json
import logging
import os
import time

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TABLE = boto3.resource("dynamodb").Table(os.environ["AUTH_PARTNERS_TABLE"])
_TTL = int(os.environ.get("PARTNERS_CACHE_TTL", "300"))
_NEGATIVE_TTL = 30

# Module-scoped cache reused across warm invocations: {client_id: (partner|None, expires_at)}
_cache = {}


def _log(event_name, **fields):
    logger.info(json.dumps({"event": event_name, "approach": "A", **fields}))


def _resolve(client_id):
    now = time.time()
    cached = _cache.get(client_id)
    if cached and cached[1] > now:
        return cached[0]

    item = _TABLE.get_item(Key={"client_id": client_id}).get("Item")
    if not item or not item.get("partner_id") or not item.get("tenant"):
        _cache[client_id] = (None, now + _NEGATIVE_TTL)
        return None

    partner = {"partner_id": item["partner_id"], "tenant": item["tenant"]}
    _cache[client_id] = (partner, now + _TTL)
    return partner


def lambda_handler(event, context):
    trigger_source = event.get("triggerSource")
    if trigger_source != "TokenGeneration_ClientCredentials":
        _log("pretoken_rejected", reason="unexpected_trigger_source")
        raise Exception("unexpected_trigger_source")

    client_id = event["callerContext"]["clientId"]
    partner = _resolve(client_id)
    if not partner:
        _log("pretoken_rejected", reason="unknown_client")
        raise Exception("unknown_client")  # token is NOT issued

    event["response"] = {
        "claimsAndScopeOverrideDetails": {
            "accessTokenGeneration": {
                "claimsToAddOrOverride": {
                    "partner_id": partner["partner_id"],
                    "tenant": partner["tenant"],
                }
            }
        }
    }
    _log(
        "pretoken_resolved",
        partner_id=partner["partner_id"],
        tenant=partner["tenant"],
    )
    return event
