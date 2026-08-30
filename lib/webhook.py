#!/usr/bin/env python3
"""Derive GHCR webhook URL + token from product gateway.publicIp + site host.

The token is a hash of values already in committed config, so CI and the VPS
agree without GitHub secrets. Optional WEBHOOK_SECRET on the VPS overrides it.
"""
from __future__ import annotations

import hashlib
from typing import Any

HOOK_PATH = "/_vibed/hooks/ghcr"
TOKEN_VERSION = "vibed-webhook|v1|"
PLACEHOLDER_SECRETS = frozenset({"", "change-me-webhook-secret"})


def derive_token(name: str, public_ip: str, host: str) -> str:
    raw = f"{TOKEN_VERSION}{name}|{public_ip}|{host}"
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


def webhook_spec(name: str, public_ip: str, host: str) -> dict[str, str]:
    host = (host or "").strip()
    public_ip = (public_ip or "").strip()
    url = f"https://{host}{HOOK_PATH}" if host else ""
    fallback = f"http://{public_ip}{HOOK_PATH}" if public_ip else ""
    if not url:
        url = fallback
    token = derive_token(name, public_ip, host) if (name and (public_ip or host)) else ""
    return {"url": url, "fallbackUrl": fallback, "token": token}


def webhook_from_packageconfig(conf: dict[str, Any]) -> dict[str, str]:
    existing = conf.get("webhook") or {}
    if existing.get("url") or existing.get("token"):
        return {
            "url": str(existing.get("url") or ""),
            "fallbackUrl": str(existing.get("fallbackUrl") or ""),
            "token": str(existing.get("token") or ""),
        }
    gw = (conf.get("profiles") or {}).get("gateway") or conf.get("gateway") or {}
    sites = gw.get("sites") or []
    host = ""
    if sites and isinstance(sites[0], dict):
        host = str(sites[0].get("host") or "")
    elif isinstance(conf.get("gateway"), dict):
        sites = (conf["gateway"].get("sites") or [])
        if sites and isinstance(sites[0], dict):
            host = str(sites[0].get("host") or "")
    public_ip = str(gw.get("publicIp") or gw.get("public_ip") or "")
    name = str(conf.get("name") or "app")
    return webhook_spec(name, public_ip, host)


def parse_package_tag(payload: dict[str, Any]) -> tuple[str, str]:
    """Accept {package, tag} or GitHub package-event shapes."""
    pkg = payload.get("package")
    name = ""
    tag: Any = payload.get("tag") or payload.get("package_version") or "main"
    if isinstance(pkg, dict):
        name = str(pkg.get("name") or "")
        ver = pkg.get("package_version") or {}
        if isinstance(ver, dict):
            meta = ver.get("container_metadata") or {}
            t = meta.get("tag") if isinstance(meta, dict) else None
            if isinstance(t, dict) and t.get("name"):
                tag = t.get("name")
            elif ver.get("name"):
                tag = ver.get("name")
    elif pkg:
        name = str(pkg)
    if not name:
        name = str(
            payload.get("package_name")
            or (payload.get("registry_package") or {}).get("name")
            or ""
        )
    if isinstance(tag, dict):
        tag = tag.get("name") or "main"
    return name, str(tag or "main")


def registry_matches(image: str, package: str, tag: str) -> bool:
    if not image:
        return False
    if package and package not in image:
        return False
    if not tag:
        return True
    return tag in image or image.endswith(f":{tag}") or ":main" in image
