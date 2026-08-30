#!/usr/bin/env python3
"""Minimal GHCR/GitHub package webhook → enqueue vibed update jobs."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOME = Path(os.environ.get("VIBED_UPDATE_AGENT", Path.home() / "services/vibed-infra/update-agent"))
ENV_FILE = HOME / ".env"


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


def registry_matches(image: str, package: str, tag: str) -> bool:
    if not image:
        return False
    # image like ghcr.io/org/name:tag
    return package in image and (tag in image or image.endswith(f":{tag}") or ":main" in image)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in ("/", "/_vibed/hooks/ghcr", "/hooks/ghcr"):
            self.send_response(404)
            self.end_headers()
            return
        env = load_env()
        secret = env.get("WEBHOOK_SECRET", "")
        got = self.headers.get("X-Vibed-Secret") or self.headers.get("Authorization", "").removeprefix("Bearer ")
        if secret and got != secret:
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

        # Support simplified {package, tag} or GitHub package webhook-ish shapes
        package = (
            payload.get("package")
            or payload.get("package_name")
            or (payload.get("registry_package") or {}).get("name")
            or ""
        )
        tag = payload.get("tag") or payload.get("package_version") or "main"
        if isinstance(tag, dict):
            tag = tag.get("name") or "main"

        reg = HOME / "registry"
        enqueued = 0
        if reg.is_dir():
            for role_file in reg.glob("*/*.json"):
                meta = json.loads(role_file.read_text())
                image = meta.get("image") or ""
                if package and not registry_matches(image, str(package), str(tag)):
                    continue
                if not package and not image:
                    continue
                # If package empty, enqueue all (manual ping)
                if package and not registry_matches(image, str(package), str(tag)):
                    continue
                cmd = [
                    "bash",
                    str(HOME / "enqueue.sh") if (HOME / "enqueue.sh").is_file() else str(Path(__file__).parent / "enqueue.sh"),
                    meta["installDir"],
                ]
                env2 = os.environ.copy()
                env2["UPDATE_REASON"] = "webhook"
                env2["PACKAGER_RAW"] = str(Path(__file__).resolve().parents[2])
                # Use vibed_enqueue directly via python calling shell helper
                qsh = HOME / "lib" / "update_queue.sh"
                bash = f'''
source "{qsh}"
vibed_enqueue_update "{meta["app"]}" "{meta["role"]}" "{meta["installDir"]}" "{image}" "webhook"
'''
                subprocess.run(["bash", "-c", bash], check=False, env=env2)
                enqueued += 1

        # Kick agent
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
    httpd = HTTPServer(("127.0.0.1", port), Handler)
    print(f"webhook listening on 127.0.0.1:{port}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
