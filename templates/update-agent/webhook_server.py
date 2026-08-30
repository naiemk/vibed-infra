#!/usr/bin/env python3
"""GHCR webhook → enqueue vibed update jobs.

Auth (first match):
  1. GitHub Actions OIDC JWT (Authorization: Bearer) — no shared secret
  2. Per-product token in tokens/ or optional WEBHOOK_SECRET
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOME = Path(os.environ.get("VIBED_UPDATE_AGENT", Path.home() / "services/vibed-infra/update-agent"))
ENV_FILE = HOME / ".env"
PLACEHOLDER_SECRETS = frozenset({"", "change-me-webhook-secret"})

_LIB = Path(__file__).resolve().parent / "lib"
for candidate in (_LIB, Path(__file__).resolve().parents[2] / "lib"):
    if candidate.is_dir() and str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))

try:
    from webhook import parse_package_tag, registry_matches  # type: ignore
except ImportError:

    def parse_package_tag(payload: dict) -> tuple[str, str]:
        pkg = payload.get("package")
        name = str(pkg) if pkg and not isinstance(pkg, dict) else str(payload.get("package_name") or "")
        tag = payload.get("tag") or "main"
        if isinstance(tag, dict):
            tag = tag.get("name") or "main"
        return name, str(tag)

    def registry_matches(image: str, package: str, tag: str) -> bool:
        if not image:
            return False
        if package and package not in image:
            return False
        return (not tag) or tag in image or image.endswith(f":{tag}") or ":main" in image

try:
    from github_oidc import looks_like_jwt, verify_jwt  # type: ignore
except ImportError:
    looks_like_jwt = None  # type: ignore
    verify_jwt = None  # type: ignore


def load_env() -> dict[str, str]:
    out: dict[str, str] = {}
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def allowed_tokens(env: dict[str, str]) -> set[str]:
    tokens: set[str] = set()
    secret = env.get("WEBHOOK_SECRET", "")
    if secret not in PLACEHOLDER_SECRETS:
        tokens.add(secret)
    extra = env.get("WEBHOOK_TOKEN", "")
    if extra not in PLACEHOLDER_SECRETS:
        tokens.add(extra)
    tok_dir = HOME / "tokens"
    if tok_dir.is_dir():
        for p in tok_dir.iterdir():
            if p.is_file():
                val = p.read_text().strip()
                if val:
                    tokens.add(val)
    return tokens


def bearer_token(handler: BaseHTTPRequestHandler) -> str:
    auth = handler.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        return auth[7:].strip()
    return ""


def request_secret(handler: BaseHTTPRequestHandler) -> str:
    return handler.headers.get("X-Vibed-Secret") or ""


def request_audiences(handler: BaseHTTPRequestHandler, env: dict[str, str]) -> list[str]:
    extra = [x.strip() for x in (env.get("WEBHOOK_OIDC_AUDIENCE") or "").split(",") if x.strip()]
    proto = (handler.headers.get("X-Forwarded-Proto") or "http").split(",")[0].strip()
    host = (handler.headers.get("Host") or "").strip()
    path = handler.path.split("?", 1)[0]
    out = list(extra)
    if host:
        out.append(f"{proto}://{host}{path}")
    return list(dict.fromkeys(out))


def authenticate(handler: BaseHTTPRequestHandler, env: dict[str, str]) -> tuple[bool, dict]:
    """Return (ok, oidc_claims). claims empty when using shared token."""
    bearer = bearer_token(handler)
    secret = request_secret(handler)
    allowed = allowed_tokens(env)

    if bearer and looks_like_jwt and verify_jwt and looks_like_jwt(bearer):
        try:
            claims = verify_jwt(bearer, audiences=request_audiences(handler, env))
            return True, claims
        except Exception as exc:
            sys.stderr.write("oidc reject: %s\n" % exc)
            return False, {}

    got = secret or bearer
    if got and got in allowed:
        return True, {}
    if allowed or bearer:
        return False, {}
    # No tokens on disk and no JWT — refuse (do not leave the hook open)
    return False, {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_POST(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] not in ("/", "/_vibed/hooks/ghcr", "/hooks/ghcr"):
            self.send_response(404)
            self.end_headers()
            return
        env = load_env()
        ok, claims = authenticate(self, env)
        if not ok:
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"unauthorized")
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        package, tag = parse_package_tag(payload)
        owner = str(claims.get("repository_owner") or "").lower()

        reg = HOME / "registry"
        enqueued = 0
        qsh = HOME / "lib" / "update_queue.sh"
        if reg.is_dir() and qsh.is_file():
            for role_file in reg.glob("*/*.json"):
                meta = json.loads(role_file.read_text())
                image = meta.get("image") or ""
                if owner and owner not in image.lower():
                    continue
                if package and not registry_matches(image, str(package), str(tag)):
                    continue
                if not package and not image:
                    continue
                bash = f'''
source "{qsh}"
vibed_enqueue_update "{meta["app"]}" "{meta["role"]}" "{meta["installDir"]}" "{image}" "webhook"
'''
                env2 = os.environ.copy()
                env2["UPDATE_REASON"] = "webhook"
                subprocess.run(["bash", "-c", bash], check=False, env=env2)
                enqueued += 1

        agent = HOME / "agent.sh"
        if agent.is_file():
            subprocess.Popen(["bash", str(agent)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        body = json.dumps({"ok": True, "enqueued": enqueued}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"vibed update webhook\n")


def main() -> int:
    env = load_env()
    port = int(env.get("WEBHOOK_PORT") or os.environ.get("WEBHOOK_PORT") or "19200")
    HOME.mkdir(parents=True, exist_ok=True)
    # 0.0.0.0 so the gateway container can reach us via host.docker.internal.
    # Do not open WEBHOOK_PORT on the public firewall; only 80/443.
    httpd = HTTPServer(("0.0.0.0", port), Handler)
    print(f"webhook listening on 0.0.0.0:{port}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
