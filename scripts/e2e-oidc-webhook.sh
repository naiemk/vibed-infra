#!/usr/bin/env bash
# E2E: mint a real GitHub Actions OIDC JWT and POST it at a local webhook.
# Requires a GHA job with permissions: id-token: write.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  if [[ "${REQUIRE_OIDC_E2E:-}" == "1" ]]; then
    echo "e2e-oidc: ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN missing (need id-token: write)" >&2
    exit 1
  fi
  echo "e2e-oidc: skip (not a GitHub Actions OIDC job)"
  exit 0
fi

OWNER="${GITHUB_REPOSITORY_OWNER:-octocat}"
IMAGE="ghcr.io/${OWNER}/e2e-oidc:main"
TD="$(mktemp -d)"
cleanup() {
  if [[ -n "${PROC:-}" ]]; then
    kill "$PROC" 2>/dev/null || true
    wait "$PROC" 2>/dev/null || true
  fi
  rm -rf "$TD"
}
trap cleanup EXIT

mkdir -p "$TD/lib" "$TD/tokens" "$TD/registry/e2e" "$TD/queue" "$TD/processing" "$TD/done" "$TD/failed"
cp -f "$ROOT/lib/update_queue.sh" "$TD/lib/update_queue.sh"
cp -f "$ROOT/lib/webhook.py" "$TD/lib/webhook.py"
cp -f "$ROOT/lib/github_oidc.py" "$TD/lib/github_oidc.py"
python3 - <<PY
import json
from pathlib import Path
td = Path("$TD")
(td / "registry" / "e2e" / "api.json").write_text(json.dumps({
    "app": "e2e", "role": "api", "installDir": "/tmp/e2e-oidc",
    "image": "$IMAGE",
}) + "\n")
PY

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
HOOK="http://127.0.0.1:${PORT}/_vibed/hooks/ghcr"
echo "WEBHOOK_SECRET=" >"$TD/.env"
echo "WEBHOOK_PORT=${PORT}" >>"$TD/.env"

export VIBED_UPDATE_AGENT="$TD"
export HOOK_PORT="$PORT"
python3 "$ROOT/templates/update-agent/webhook_server.py" >>"$TD/webhook.log" 2>&1 &
PROC=$!

python3 - <<'PY'
import socket, time, os, sys
port = int(os.environ["HOOK_PORT"])
deadline = time.time() + 8
while time.time() < deadline:
    s = socket.socket()
    try:
        s.settimeout(0.3)
        s.connect(("127.0.0.1", port))
        sys.exit(0)
    except OSError:
        time.sleep(0.1)
    finally:
        s.close()
print("webhook did not listen", file=sys.stderr)
sys.exit(1)
PY

# Happy path: notify-vps-pull.py mints OIDC and POSTs (same code users run)
python3 "$ROOT/github/notify-vps-pull.py" --strict --url "$HOOK" --image "$IMAGE" --tag main

n="$(find "$TD/queue" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n" -eq 1 ]] || { echo "expected 1 queued job, got $n" >&2; cat "$TD/webhook.log" >&2; exit 1; }

# Wrong audience must 401
python3 - <<PY
import json, os, sys, urllib.error, urllib.request
sys.path.insert(0, "$ROOT/lib")
from github_oidc import fetch_actions_id_token
hook = "$HOOK"
token = fetch_actions_id_token("https://evil.example/_vibed/hooks/ghcr")
assert token, "failed to mint wrong-audience token"
req = urllib.request.Request(
    hook,
    data=b'{"package":"e2e-oidc","tag":"main"}',
    method="POST",
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
)
try:
    urllib.request.urlopen(req, timeout=10)
    raise SystemExit("expected 401 for wrong audience")
except urllib.error.HTTPError as e:
    if e.code != 401:
        raise SystemExit(f"expected 401, got {e.code}")
print("oidc wrong-audience → 401")
PY

# Garbage bearer must 401
python3 - <<PY
import urllib.error, urllib.request
req = urllib.request.Request(
    "$HOOK",
    data=b'{"package":"e2e-oidc","tag":"main"}',
    method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Bearer not-a-jwt"},
)
try:
    urllib.request.urlopen(req, timeout=5)
    raise SystemExit("expected 401 for garbage bearer")
except urllib.error.HTTPError as e:
    if e.code != 401:
        raise SystemExit(f"expected 401, got {e.code}")
print("oidc garbage bearer → 401")
PY

echo "e2e-oidc-webhook OK (GitHub OIDC mint + local webhook)"
