import base64
import json
import os
import urllib.error
import urllib.request


HTTP_TIMEOUT_SECONDS = 4


def _response(status_code, body, content_type="application/json"):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": content_type,
        },
        "body": body,
    }


def _get_http_method(event):
    return (
        event.get("httpMethod")
        or event.get("requestContext", {}).get("http", {}).get("method")
        or ""
    ).upper()


def _get_body(event):
    body = event.get("body")
    if not body:
        return None

    if event.get("isBase64Encoded"):
        try:
            return base64.b64decode(body)
        except (ValueError, TypeError):
            return None

    return body.encode("utf-8")


def lambda_handler(event, context):
    if _get_http_method(event) != "POST":
        return _response(
            405,
            json.dumps({"error": "method_not_allowed"}),
        )

    request_body = _get_body(event)
    if not request_body:
        return _response(
            400,
            json.dumps({"error": "invalid_request", "error_description": "empty body"}),
        )

    cognito_token_url = os.environ["COGNITO_TOKEN_URL"]
    request = urllib.request.Request(
        cognito_token_url,
        data=request_body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            response_body = response.read().decode("utf-8")
            content_type = response.headers.get("Content-Type", "application/json")
            return _response(response.status, response_body, content_type)
    except urllib.error.HTTPError as error:
        response_body = error.read().decode("utf-8")
        content_type = error.headers.get("Content-Type", "application/json")
        return _response(error.code, response_body, content_type)
    except (urllib.error.URLError, TimeoutError):
        return _response(
            502,
            json.dumps(
                {
                    "error": "bad_gateway",
                    "error_description": "cognito communication failure",
                }
            ),
        )
