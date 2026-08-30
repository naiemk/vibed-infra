#!/usr/bin/env python3
"""Verify GitHub Actions OIDC JWTs with stdlib + openssl (no PyJWT).

Used by the VPS webhook to accept image-push notify without a shared secret.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

GITHUB_OIDC_ISS = "https://token.actions.githubusercontent.com"
JWKS_URL = "https://token.actions.githubusercontent.com/.well-known/jwks"

_jwks_cache: dict[str, Any] | None = None
_jwks_cache_at = 0.0
_JWKS_TTL = 3600


def b64url_decode(data: str) -> bytes:
    pad = "=" * ((4 - len(data) % 4) % 4)
    return base64.urlsafe_b64decode(data + pad)


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(body)]) + body


def _der_int(val: bytes) -> bytes:
    if not val:
        val = b"\x00"
    if val[0] & 0x80:
        val = b"\x00" + val
    return b"\x02" + _der_len(len(val)) + val


def _der_seq(body: bytes) -> bytes:
    return b"\x30" + _der_len(len(body)) + body


def jwk_to_pem(jwk: dict[str, Any]) -> str:
    n = b64url_decode(str(jwk["n"]))
    e = b64url_decode(str(jwk["e"]))
    rsa_key = _der_seq(_der_int(n) + _der_int(e))
    bitstr = b"\x03" + _der_len(len(rsa_key) + 1) + b"\x00" + rsa_key
    alg = bytes.fromhex("300d06092a864886f70d0101010500")
    spki = _der_seq(alg + bitstr)
    wrapped = base64.encodebytes(spki).decode("ascii")
    return "-----BEGIN PUBLIC KEY-----\n" + wrapped + "-----END PUBLIC KEY-----\n"


def verify_rs256(pem: str, signing_input: bytes, signature: bytes) -> bool:
    with tempfile.TemporaryDirectory() as td:
        pub = Path(td) / "pub.pem"
        sigf = Path(td) / "sig.bin"
        data = Path(td) / "data.bin"
        pub.write_text(pem)
        sigf.write_bytes(signature)
        data.write_bytes(signing_input)
        r = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(pub),
                "-signature",
                str(sigf),
                str(data),
            ],
            capture_output=True,
            text=True,
        )
        return r.returncode == 0


def split_jwt(token: str) -> tuple[dict[str, Any], dict[str, Any], bytes, bytes]:
    parts = token.split(".")
    if len(parts) != 3 or not all(parts):
        raise ValueError("malformed jwt")
    header = json.loads(b64url_decode(parts[0]))
    payload = json.loads(b64url_decode(parts[1]))
    signing_input = f"{parts[0]}.{parts[1]}".encode("ascii")
    signature = b64url_decode(parts[2])
    return header, payload, signing_input, signature


def looks_like_jwt(token: str) -> bool:
    return token.count(".") == 2 and len(token) > 20


def _aud_list(aud: Any) -> list[str]:
    if aud is None:
        return []
    if isinstance(aud, list):
        return [str(x) for x in aud]
    return [str(aud)]


def load_jwks(*, jwks: dict[str, Any] | None = None) -> dict[str, Any]:
    if jwks is not None:
        return jwks
    path = os.environ.get("WEBHOOK_OIDC_JWKS_FILE") or ""
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    global _jwks_cache, _jwks_cache_at
    now = time.time()
    if _jwks_cache is not None and (now - _jwks_cache_at) < _JWKS_TTL:
        return _jwks_cache
    url = os.environ.get("WEBHOOK_OIDC_JWKS_URL") or JWKS_URL
    req = urllib.request.Request(url, headers={"User-Agent": "vibed-infra-webhook"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
    _jwks_cache = data
    _jwks_cache_at = now
    return data


def verify_jwt(
    token: str,
    *,
    audiences: list[str],
    issuer: str = GITHUB_OIDC_ISS,
    jwks: dict[str, Any] | None = None,
    now: int | None = None,
    leeway: int = 60,
) -> dict[str, Any]:
    """Return claims if valid; raise ValueError otherwise."""
    header, payload, signing_input, signature = split_jwt(token)
    if header.get("alg") != "RS256":
        raise ValueError("alg")
    iss = os.environ.get("WEBHOOK_OIDC_ISS") or issuer
    if payload.get("iss") != iss:
        raise ValueError("iss")
    ts = int(now if now is not None else time.time())
    exp = payload.get("exp")
    if exp is None or ts > int(exp) + leeway:
        raise ValueError("exp")
    nbf = payload.get("nbf")
    if nbf is not None and ts + leeway < int(nbf):
        raise ValueError("nbf")
    aud_ok = set(_aud_list(payload.get("aud")))
    if not aud_ok.intersection(audiences):
        raise ValueError("aud")
    keys = load_jwks(jwks=jwks).get("keys") or []
    kid = header.get("kid")
    chosen = None
    for k in keys:
        if kid and k.get("kid") == kid:
            chosen = k
            break
        if not kid and k.get("kty") == "RSA":
            chosen = k
            break
    if not chosen:
        raise ValueError("kid")
    pem = jwk_to_pem(chosen)
    if not verify_rs256(pem, signing_input, signature):
        raise ValueError("sig")
    return payload


def fetch_actions_id_token(audience: str) -> str:
    """Mint a GitHub Actions OIDC JWT for audience. Empty if not in Actions."""
    url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL") or ""
    tok = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN") or ""
    if not url or not tok:
        return ""
    sep = "&" if "?" in url else "?"
    req = urllib.request.Request(
        f"{url}{sep}audience={urllib.parse.quote(audience, safe='')}",
        headers={"Authorization": f"Bearer {tok}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode())
    return str(data.get("value") or "")


def sign_jwt_rs256(header: dict[str, Any], payload: dict[str, Any], key_pem_path: str) -> str:
    h = b64url_encode(json.dumps(header, separators=(",", ":")).encode())
    p = b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    sig = subprocess.check_output(
        ["openssl", "dgst", "-sha256", "-sign", key_pem_path],
        input=f"{h}.{p}".encode("ascii"),
    )
    return f"{h}.{p}.{b64url_encode(sig)}"


def rsa_jwk_from_pubpem(pem: str, kid: str = "test") -> dict[str, Any]:
    """Build a JWK from a PEM public key (tests)."""
    with tempfile.TemporaryDirectory() as td:
        pub = Path(td) / "pub.pem"
        pub.write_text(pem)
        mod = subprocess.check_output(
            ["openssl", "rsa", "-pubin", "-in", str(pub), "-modulus", "-noout"],
            text=True,
        )
        hexmod = mod.strip().split("=", 1)[1]
        n = bytes.fromhex(hexmod)
        txt = subprocess.check_output(
            ["openssl", "rsa", "-pubin", "-in", str(pub), "-text", "-noout"],
            text=True,
        )
    exp = 65537
    for line in txt.splitlines():
        if "Exponent:" in line:
            exp = int(line.split(":", 1)[1].split("(")[0].strip())
            break
    e = exp.to_bytes((exp.bit_length() + 7) // 8, "big")
    return {"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": b64url_encode(n), "e": b64url_encode(e)}
