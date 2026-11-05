"""Read-only GHCR publication preflight. Only MANIFEST_UNKNOWN proves absence."""

import base64
import http.client
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class Refusal(Exception):
    """The registry did not prove that publication is safe."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward credentials to a redirect target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, headers):
    try:
        return urllib.request.build_opener(NoRedirect).open(
            urllib.request.Request(url, headers=headers, method="GET"), timeout=30
        )
    except urllib.error.HTTPError:
        raise
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, http.client.HTTPException) as exc:
        # Do not log request headers, tokens, or arbitrary upstream responses.
        raise Refusal(f"registry lookup failed ({type(exc).__name__}); no publication allowed") from None


def json_body(response):
    try:
        return json.loads(response.read(1024 * 1024))
    except (ValueError, OSError, http.client.HTTPException):
        raise Refusal("registry returned invalid JSON; no publication allowed") from None


def parse_images(value):
    images = value.split()
    if not images:
        raise Refusal("images must contain at least one GHCR version tag")
    parsed = []
    for image in images:
        match = re.fullmatch(r"ghcr\.io/([A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*(?:/[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*)+):([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})", image)
        if not match or not re.match(r"v?[0-9]+\.[0-9]+\.[0-9]+", match[2]):
            raise Refusal("images must be fully qualified GHCR version tags; moving tags and digests are refused")
        # GitHub owner names can have capitals; GHCR repository paths cannot.
        # Tags are case-sensitive, so normalize only the repository.
        parsed.append((image, match[1].lower(), match[2]))
    return parsed


def bearer_token(repository, username, password):
    headers = {"Accept": "application/json"}
    if username and password:
        basic = base64.b64encode(f"{username}:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {basic}"
    elif username or password:
        raise Refusal("registry username and token must be supplied together")
    query = urllib.parse.urlencode({"service": "ghcr.io", "scope": f"repository:{repository}:pull"})
    try:
        with request(f"https://ghcr.io/token?{query}", headers) as response:
            data = json_body(response)
    except urllib.error.HTTPError as exc:
        raise Refusal(f"registry authentication failed (HTTP {exc.code}); no publication allowed") from None
    token = (data.get("token") or data.get("access_token")) if isinstance(data, dict) else None
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9._~+/-]+=*", token):
        raise Refusal("registry returned no valid bearer token; no publication allowed")
    return token


def check_image(image, repository, tag, token):
    headers = {
        "Authorization": f"Bearer {token}",
        # Unsupported types can also return MANIFEST_UNKNOWN. Extend this list
        # and the manifest-type tests before a caller publishes a new format.
        "Accept": ", ".join([
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ]),
    }
    try:
        with request(f"https://ghcr.io/v2/{repository}/manifests/{tag}", headers) as response:
            digest = response.headers.get("Docker-Content-Digest", "")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                raise Refusal(f"{image}: registry returned no valid digest; no publication allowed")
            raise Refusal(f"{image}: existing digest {digest}; refusing to overwrite a version tag, including on retry")
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise Refusal(f"{image}: lookup failed (HTTP {exc.code}); no publication allowed") from None
        with exc:
            body = json_body(exc)
        errors = body.get("errors") if isinstance(body, dict) else None
        if not isinstance(errors, list) or not errors or any(
            not isinstance(error, dict) or error.get("code") != "MANIFEST_UNKNOWN" for error in errors
        ):
            raise Refusal(f"{image}: HTTP 404 did not prove MANIFEST_UNKNOWN; check package access before retrying")
    print(f"{image}: MANIFEST_UNKNOWN confirmed; version tag is absent", flush=True)


def guard(images, username="", password=""):
    parsed = parse_images(images)  # Validate every ref before the first network call.
    tokens = {}
    for image, repository, tag in parsed:
        if repository not in tokens:
            tokens[repository] = bearer_token(repository, username, password)
        check_image(image, repository, tag, tokens[repository])


def main():
    try:
        guard(os.environ.get("INPUT_IMAGES", ""), os.environ.get("REGISTRY_USERNAME", ""), os.environ.get("REGISTRY_TOKEN", ""))
    except Refusal as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
