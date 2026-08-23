#!/usr/bin/env python3
"""Tiny notes API — stdlib only. Opaque app; infra never parses this."""
from __future__ import annotations

import json
import os
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

DB_PATH = os.environ.get("DB_PATH", "/data/app.db")
TOKEN = os.environ.get("API_TOKEN", "")
PORT = int(os.environ.get("PORT", "8080"))


def connect() -> sqlite3.Connection:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    con.execute(
        "CREATE TABLE IF NOT EXISTS notes ("
        "id INTEGER PRIMARY KEY, author TEXT, body TEXT, created_at INTEGER)"
    )
    return con


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, obj: object) -> None:
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/health":
            self._json(200, {"ok": True, "service": "hello-vps-api"})
            return
        if path == "/api/notes":
            con = connect()
            rows = con.execute(
                "SELECT id, author, body, created_at FROM notes ORDER BY id DESC LIMIT 50"
            ).fetchall()
            con.close()
            self._json(
                200,
                {
                    "notes": [
                        {"id": r[0], "author": r[1], "body": r[2], "createdAt": r[3]}
                        for r in rows
                    ]
                },
            )
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path != "/api/notes":
            self._json(404, {"error": "not found"})
            return
        auth = self.headers.get("Authorization", "")
        if TOKEN and auth != f"Bearer {TOKEN}":
            self._json(401, {"error": "unauthorized"})
            return
        n = int(self.headers.get("Content-Length", "0") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}")
        author = str(payload.get("author") or "anon")[:64]
        body = str(payload.get("body") or "")[:500]
        if not body:
            self._json(400, {"error": "body required"})
            return
        con = connect()
        cur = con.execute(
            "INSERT INTO notes (author, body, created_at) VALUES (?, ?, ?)",
            (author, body, int(time.time())),
        )
        con.commit()
        note_id = cur.lastrowid
        con.close()
        self._json(201, {"id": note_id, "author": author, "body": body})

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    connect().close()
    print(f"hello-vps-api listening on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
