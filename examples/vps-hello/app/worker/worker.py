#!/usr/bin/env python3
"""Post a heartbeat note to the API on an interval."""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

API = os.environ.get("API_URL", "http://hello-api:8080").rstrip("/")
TOKEN = os.environ.get("API_TOKEN", "")
ROLE = os.environ.get("WORKER_ROLE", "heartbeat")
INTERVAL = int(os.environ.get("INTERVAL_SEC", "60"))


def post() -> None:
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(
        f"{API}/api/notes",
        data=json.dumps({"author": ROLE, "body": f"heartbeat from {ROLE}"}).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"posted {resp.status}", flush=True)


def main() -> None:
    print(f"worker role={ROLE} api={API} interval={INTERVAL}s", flush=True)
    while True:
        try:
            post()
        except urllib.error.URLError as exc:
            print(f"error {exc}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
