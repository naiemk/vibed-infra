#!/usr/bin/env python3
"""Load product vibed-infra-config + component configs; compile to packageconfig."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from load_config import load_packageconfig


def load_product(product_dir: Path) -> dict[str, Any]:
    tpl = product_dir / "templates"
    infra_path = tpl / "vibed-infra-config.yml"
    if not infra_path.is_file():
        raise FileNotFoundError(f"missing {infra_path}")
    infra = load_packageconfig(infra_path)
    refs = infra.get("templates") or {}
    components: dict[str, dict[str, Any]] = {}
    for key in ("api", "ui", "nodes"):
        rel = refs.get(key) or f"{key}-config.yaml"
        path = tpl / rel
        if not path.is_file():
            raise FileNotFoundError(f"missing component config {path}")
        components[key] = load_packageconfig(path)
    return {"infra": infra, "components": components, "templates_dir": tpl}


def _slug(name: str) -> str:
    return name.replace("_", "-")


def _auto_update_block(section: dict[str, Any] | None, prefix: str) -> dict[str, Any]:
    section = section or {}
    enabled = section.get("enabled", False)
    flag = section.get("flag") or f"{prefix}_AUTO_UPDATE"
    return {
        "flag": flag,
        "intervalEnv": section.get("intervalEnv") or f"{prefix}_AUTO_UPDATE_INTERVAL_MIN",
        "offset": section.get("offset", 0),
        "stopTimeoutEnv": section.get("stopTimeoutEnv") or f"{prefix}_STOP_TIMEOUT",
        "_enabled": bool(enabled),
    }


def compile_packageconfig(
    product: dict[str, Any],
    *,
    raw_base: str = "",
    packager_raw: str = "https://raw.githubusercontent.com/naiemk/vibed-infra/main",
) -> dict[str, Any]:
    infra = product["infra"]
    comps = product["components"]
    name = _slug(str(infra.get("name") or "app"))
    # Shared host edge by default so multiple products join one gateway.
    network = (infra.get("network") or {}).get("edge") or "vps-edge"
    api = comps["api"]
    ui = comps["ui"]
    nodes = comps["nodes"]
    gw = infra.get("gateway") or {}
    sites_in = gw.get("sites") or []
    auto = infra.get("autoUpdate") or {}

    api_au = _auto_update_block(auto.get("api"), "API")
    ui_au = _auto_update_block(auto.get("ui"), "UI")
    nodes_au = _auto_update_block(auto.get("nodes"), "NODES")
    gw_au = _auto_update_block(auto.get("gateway"), "GATEWAY")

    api_name = f"{name}-api"
    ui_name = f"{name}-ui"
    worker_name = f"{name}-worker"

    sites: list[dict[str, Any]] = []
    for site in sites_in:
        host = site["host"]
        entry = {
            "host": host,
            "backend": site.get("backend") or api_name,
            "backendPort": site.get("backendPort") or api.get("port") or 8080,
            "ui": site.get("ui") or ui_name,
            "uiPort": site.get("uiPort") or ui.get("port") or 80,
            "healthPath": site.get("healthPath") or "/api/health",
            "tlsCertDir": site.get("tlsCertDir") or f"/etc/letsencrypt/live/{host}",
        }
        if site.get("aliases"):
            entry["aliases"] = site["aliases"]
        if site.get("createPath"):
            entry["createPath"] = site["createPath"]
        sites.append(entry)

    nginx_image = (infra.get("images") or {}).get("nginx") or gw.get("nginxImage") or "nginx:alpine"

    return {
        "name": name,
        "version": infra.get("version") or 1,
        "rawBase": raw_base,
        "packagerRaw": packager_raw,
        "network": {"edge": network},
        "images": {
            "backend": api.get("image") or f"{name}-api:local",
            "ui": ui.get("image") or f"{name}-ui:local",
            "worker": nodes.get("image") or f"{name}-worker:local",
            "nginx": nginx_image,
        },
        "autoUpdate": {"lockFile": "/var/lock/infra-auto-update.lock"},
        "profiles": {
            "api": {
                "role": "backend",
                "templates": {
                    "config": "api-app.yaml",
                    "envExample": ".env.api.example",
                },
                "startScript": "start-api.sh",
                "updateScript": "update-api.sh",
                "autoUpdate": {k: v for k, v in api_au.items() if not k.startswith("_")},
            },
            "ui": {
                "role": "ui",
                "templates": {"envExample": ".env.ui.example"},
                "startScript": "start-ui.sh",
                "updateScript": "update-ui.sh",
                "autoUpdate": {k: v for k, v in ui_au.items() if not k.startswith("_")},
            },
            "nodes": {
                "role": "workers",
                "templates": {
                    "config": "nodes-workers.yaml",
                    "envExample": ".env.nodes.example",
                    "compose": "docker-compose.workers.yml",
                },
                "startScript": "start-nodes.sh",
                "updateScript": "update-nodes.sh",
                "autoUpdate": {k: v for k, v in nodes_au.items() if not k.startswith("_")},
                "workers": {
                    "services": [
                        {
                            "name": "worker",
                            "containerName": worker_name,
                            "roleEnv": "WORKER_ROLE=heartbeat",
                        }
                    ]
                },
            },
            "gateway": {
                "role": "gateway",
                "mode": "host-extension",
                "templates": {"envExample": ".env.gateway.example"},
                "startScript": "start-gateway.sh",
                "updateScript": "update-gateway.sh",
                "autoUpdate": {
                    "flags": [gw_au.get("flag") or "GATEWAY_AUTO_UPDATE"],
                    "intervalEnv": gw_au.get("intervalEnv"),
                    "offset": gw_au.get("offset", 20),
                    "stopTimeoutEnv": gw_au.get("stopTimeoutEnv"),
                },
                "sites": sites,
            },
        },
        "_meta": {
            "apiContainer": api_name,
            "uiContainer": ui_name,
            "workerContainer": worker_name,
            "gatewayContainer": "vps-gateway",
            "productName": name,
            "network": network,
            "apiPort": api.get("port") or 8080,
            "uiPort": ui.get("port") or 80,
        },
    }


def dump_yaml(data: Any, indent: int = 0) -> str:
    """Minimal YAML emitter for packageconfig (no PyYAML required)."""
    sp = "  " * indent
    if isinstance(data, dict):
        lines: list[str] = []
        for key, val in data.items():
            if key.startswith("_"):
                continue
            if isinstance(val, (dict, list)):
                lines.append(f"{sp}{key}:")
                lines.append(dump_yaml(val, indent + 1).rstrip())
            elif isinstance(val, bool):
                lines.append(f"{sp}{key}: {'true' if val else 'false'}")
            elif val is None:
                lines.append(f"{sp}{key}:")
            else:
                s = str(val)
                if any(c in s for c in ":{}[]#&*!|>'\"%@`"):
                    s = json.dumps(s)
                lines.append(f"{sp}{key}: {s}")
        return "\n".join(lines) + ("\n" if lines else "")
    if isinstance(data, list):
        lines = []
        for item in data:
            if isinstance(item, dict):
                first = True
                for k, v in item.items():
                    pref = "- " if first else "  "
                    first = False
                    if isinstance(v, list):
                        lines.append(f"{sp}{pref}{k}:")
                        for sub in v:
                            lines.append(f"{sp}  - {sub}")
                    else:
                        lines.append(f"{sp}{pref}{k}: {v}")
            else:
                lines.append(f"{sp}- {item}")
        return "\n".join(lines) + ("\n" if lines else "")
    return f"{sp}{data}\n"


def write_app_config(component: dict[str, Any], out: Path) -> None:
    cfg = component.get("config")
    if cfg is None:
        out.write_text("# opaque app config\n", encoding="utf-8")
        return
    if isinstance(cfg, dict):
        out.write_text(dump_yaml(cfg), encoding="utf-8")
    else:
        out.write_text(str(cfg), encoding="utf-8")
