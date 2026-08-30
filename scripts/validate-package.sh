#!/usr/bin/env bash
# Smoke checks before npm publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

test -x install.sh
test -x package.sh
test -f lib/fetch.sh
test -f lib/load_config.py
test -f lib/product_config.py
test -f lib/package.py
test -f templates/generic/start-api.sh
test -f schema/packageconfig.md

bash -n install.sh
bash -n start.sh
bash -n update.sh
bash -n package.sh

python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'lib')
from product_config import load_product, compile_packageconfig
p = load_product(Path('examples/vps-hello'))
c = compile_packageconfig(p, raw_base='/dist')
assert c['profiles']['api']['role'] == 'backend'
assert c['profiles']['ui']['role'] == 'ui'
assert c['profiles']['gateway']['sites'][0]['host'] == 'hello.example.com'
assert c['profiles']['gateway'].get('publicIp') == '203.0.113.10'
assert c['profiles']['gateway'].get('tlsEmail') == 'ops@example.com'
assert c['webhook']['url'] == 'https://hello.example.com/_vibed/hooks/ghcr'
assert c['webhook']['fallbackUrl'] == 'http://203.0.113.10/_vibed/hooks/ghcr'
assert len(c['webhook']['token']) == 32
print('product_config ok')
"

bash examples/vps-hello/package.sh
test -f examples/vps-hello/dist/install-api.sh
test -f examples/vps-hello/dist/packageconfig.yaml
test -f examples/vps-hello/dist/DNS-SKILL.md
test -f examples/vps-hello/dist/notify-vps-pull.py
grep -q "hello.example.com" examples/vps-hello/dist/DNS-SKILL.md
grep -q "203.0.113.10" examples/vps-hello/dist/DNS-SKILL.md
grep -q "webhook:" examples/vps-hello/dist/packageconfig.yaml
grep -q "_vibed/hooks/ghcr" examples/vps-hello/dist/packageconfig.yaml
test -x examples/vps-hello/dist/start-api.sh

python3 -m py_compile lib/webhook.py lib/product_config.py lib/generate.py lib/github_oidc.py \
  templates/update-agent/webhook_server.py github/notify-vps-pull.py

# Persistlog round-trip
python3 - <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, "lib")
from persistlog import append, seal, replay, iter_events
td = Path(tempfile.mkdtemp())
append(td, "notes", "note.created", {"body": "hi"}, fsync=False)
append(td, "notes", "note.created", {"body": "yo"}, fsync=False)
seal(td / "notes")
n = sum(1 for _ in iter_events(td, "notes"))
assert n == 2, n
def apply(e, s):
    return s + [e["payload"]["body"]]
assert replay(td, "notes", apply, []) == ["hi", "yo"]
print("persistlog ok")
PY

# Update queue enqueue smoke
bash -n templates/update-agent/agent.sh
bash -n templates/update-agent/install-agent.sh
bash -n lib/update_queue.sh
bash -n lib/host_gateway.sh

export GATEWAY_HOME="${TMPDIR:-/tmp}/vibed-gw-dry-$$"
export VIBED_HOME="${TMPDIR:-/tmp}/vibed-home-dry-$$"
mkdir -p "$GATEWAY_HOME" "$VIBED_HOME"
for prof in api ui nodes gateway; do
  DEST="${TMPDIR:-/tmp}/hello-dist-dry-${prof}-$$"
  mkdir -p "$DEST"
  PACKAGER_RAW="$ROOT" INSTALL_DIR="$DEST" GATEWAY_HOME="$GATEWAY_HOME" VIBED_HOME="$VIBED_HOME" \
    TLS_MODE=lab \
    bash "examples/vps-hello/dist/install-${prof}.sh"
  test -f "$DEST/.env"
  test -x "$DEST/start-${prof}.sh" || test -x "$DEST/start-api.sh"
  if [[ "$prof" == gateway ]]; then
    test -f "$GATEWAY_HOME/.vibed-host-gateway"
    test -f "$GATEWAY_HOME/apps/hello-vps/sites.conf"
    test -x "$GATEWAY_HOME/setup-tls.sh"
    bash -n "$GATEWAY_HOME/setup-tls.sh"
    test -f "$GATEWAY_HOME/certs/fullchain.pem"
    test -f "$GATEWAY_HOME/.vibed-tls-state"
    grep -q "hello.example.com" "$GATEWAY_HOME/apps/hello-vps/sites.conf"
    grep -q "_vibed/hooks/" "$GATEWAY_HOME/apps/hello-vps/sites.conf"
  fi
  rm -rf "$DEST"
done
test -f "$VIBED_HOME/update-agent/tokens/hello-vps"
test -f "$VIBED_HOME/update-agent/registry/hello-vps/api.json"
test -f "$VIBED_HOME/update-agent/registry/hello-vps/ui.json"
test -f "$VIBED_HOME/update-agent/lib/github_oidc.py"
pkill -f "$VIBED_HOME/update-agent/webhook_server.py" >/dev/null 2>&1 || true
rm -rf "$GATEWAY_HOME" "$VIBED_HOME"

# DNS-SKILL bakes gateway.publicIp when set
grep -q "203.0.113.10" examples/vps-hello/dist/DNS-SKILL.md
grep -q "hello.example.com" examples/vps-hello/dist/DNS-SKILL.md

python3 lib/generate.py examples/vps-hello/dist/packageconfig.yaml --profile gateway --mode app \
  -o /tmp/hello-vps-sites.conf
grep -q "hello.example.com" /tmp/hello-vps-sites.conf
grep -q "hello-vps-api:8080" /tmp/hello-vps-sites.conf
grep -q "_vibed/hooks/" /tmp/hello-vps-sites.conf
grep -q "host.docker.internal:19200" /tmp/hello-vps-sites.conf

# Webhook token + notify parser + live enqueue
python3 - <<'PY'
import json, os, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request
from pathlib import Path
sys.path.insert(0, "lib")
from webhook import derive_token, webhook_spec, parse_package_tag, registry_matches
from product_config import load_product, compile_packageconfig

c = compile_packageconfig(load_product(Path("examples/vps-hello")), raw_base="/dist")
spec = webhook_spec("hello-vps", "203.0.113.10", "hello.example.com")
assert c["webhook"] == spec
assert spec["token"] == derive_token("hello-vps", "203.0.113.10", "hello.example.com")
assert parse_package_tag({"package": "hello-vps-api", "tag": "main"}) == ("hello-vps-api", "main")
assert parse_package_tag({
    "package": {
        "name": "hello-vps-api",
        "package_version": {"container_metadata": {"tag": {"name": "main"}}},
    }
}) == ("hello-vps-api", "main")
assert registry_matches("ghcr.io/x/hello-vps-api:main", "hello-vps-api", "main")

td = Path(tempfile.mkdtemp())
(td / "lib").mkdir(parents=True)
(td / "tokens").mkdir()
(td / "registry" / "hello-vps").mkdir(parents=True)
for d in ("queue", "processing", "done", "failed"):
    (td / d).mkdir()
(td / "lib" / "update_queue.sh").write_text(Path("lib/update_queue.sh").read_text())
(td / "lib" / "webhook.py").write_text(Path("lib/webhook.py").read_text())
(td / "lib" / "github_oidc.py").write_text(Path("lib/github_oidc.py").read_text())
(td / "registry" / "hello-vps" / "api.json").write_text(json.dumps({
    "app": "hello-vps", "role": "api", "installDir": "/tmp/x",
    "image": "ghcr.io/x/hello-vps-api:main",
}))
(td / "tokens" / "hello-vps").write_text(spec["token"] + "\n")

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
(td / ".env").write_text(f"WEBHOOK_SECRET=\nWEBHOOK_PORT={port}\n")
log = open(td / "webhook.log", "w")
proc = subprocess.Popen(
    [sys.executable, str(Path("templates/update-agent/webhook_server.py").resolve())],
    env={**os.environ, "VIBED_UPDATE_AGENT": str(td)},
    stdout=log, stderr=subprocess.STDOUT,
)
try:
    time.sleep(0.5)
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/_vibed/hooks/ghcr",
        data=b'{"package":"hello-vps-api","tag":"main"}',
        method="POST",
        headers={"Content-Type": "application/json", "X-Vibed-Secret": spec["token"]},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = json.loads(resp.read().decode())
    assert body.get("ok") is True and body.get("enqueued") == 1, body
    bad = urllib.request.Request(
        f"http://127.0.0.1:{port}/_vibed/hooks/ghcr",
        data=b'{"package":"hello-vps-api","tag":"main"}',
        method="POST",
        headers={"Content-Type": "application/json", "X-Vibed-Secret": "nope"},
    )
    try:
        urllib.request.urlopen(bad, timeout=5)
        raise SystemExit("expected 401")
    except urllib.error.HTTPError as e:
        assert e.code == 401
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
print("webhook ok")

# Local RS256 JWT (openssl) — same verifier GitHub OIDC uses
import time as _time
from github_oidc import rsa_jwk_from_pubpem, sign_jwt_rs256, verify_jwt
kdir = Path(tempfile.mkdtemp())
subprocess.check_call(["openssl", "genrsa", "-out", str(kdir / "key.pem"), "2048"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.check_call(["openssl", "rsa", "-in", str(kdir / "key.pem"), "-pubout", "-out", str(kdir / "pub.pem")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
pub = (kdir / "pub.pem").read_text()
jwk = rsa_jwk_from_pubpem(pub, kid="test1")
jwks = {"keys": [jwk]}
now = int(_time.time())
iss = "https://oidc.test.vibed"
aud = "http://hook.test/_vibed/hooks/ghcr"
good = sign_jwt_rs256(
    {"alg": "RS256", "typ": "JWT", "kid": "test1"},
    {"iss": iss, "aud": aud, "exp": now + 300, "iat": now, "repository_owner": "acme", "repository": "acme/app"},
    str(kdir / "key.pem"),
)
claims = verify_jwt(good, audiences=[aud], issuer=iss, jwks=jwks, now=now)
assert claims["repository_owner"] == "acme"
try:
    verify_jwt(good, audiences=["https://evil.example/x"], issuer=iss, jwks=jwks, now=now)
    raise SystemExit("expected aud fail")
except ValueError as e:
    assert str(e) == "aud"
expired = sign_jwt_rs256(
    {"alg": "RS256", "typ": "JWT", "kid": "test1"},
    {"iss": iss, "aud": aud, "exp": now - 120, "iat": now - 200, "repository_owner": "acme"},
    str(kdir / "key.pem"),
)
try:
    verify_jwt(expired, audiences=[aud], issuer=iss, jwks=jwks, now=now, leeway=0)
    raise SystemExit("expected exp fail")
except ValueError as e:
    assert str(e) == "exp"
print("oidc jwt verify ok")

# Webhook accepts locally signed OIDC JWT (JWKS file, no GitHub)
td2 = Path(tempfile.mkdtemp())
(td2 / "lib").mkdir(parents=True)
for d in ("queue", "processing", "done", "failed"):
    (td2 / d).mkdir()
(td2 / "registry" / "hello-vps").mkdir(parents=True)
(td2 / "lib" / "update_queue.sh").write_text(Path("lib/update_queue.sh").read_text())
(td2 / "lib" / "webhook.py").write_text(Path("lib/webhook.py").read_text())
(td2 / "lib" / "github_oidc.py").write_text(Path("lib/github_oidc.py").read_text())
(td2 / "registry" / "hello-vps" / "api.json").write_text(json.dumps({
    "app": "hello-vps", "role": "api", "installDir": "/tmp/x",
    "image": "ghcr.io/acme/hello-vps-api:main",
}))
jwks_path = td2 / "jwks.json"
jwks_path.write_text(json.dumps(jwks))
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port2 = sock.getsockname()[1]
sock.close()
hook_aud = f"http://127.0.0.1:{port2}/_vibed/hooks/ghcr"
(td2 / ".env").write_text(f"WEBHOOK_SECRET=\nWEBHOOK_PORT={port2}\n")
oidc_jwt = sign_jwt_rs256(
    {"alg": "RS256", "typ": "JWT", "kid": "test1"},
    {"iss": iss, "aud": hook_aud, "exp": now + 300, "iat": now, "repository_owner": "acme"},
    str(kdir / "key.pem"),
)
log2 = open(td2 / "webhook.log", "w")
env2 = {**os.environ, "VIBED_UPDATE_AGENT": str(td2), "WEBHOOK_OIDC_JWKS_FILE": str(jwks_path), "WEBHOOK_OIDC_ISS": iss}
proc2 = subprocess.Popen(
    [sys.executable, str(Path("templates/update-agent/webhook_server.py").resolve())],
    env=env2, stdout=log2, stderr=subprocess.STDOUT,
)
try:
    time.sleep(0.5)
    req = urllib.request.Request(
        hook_aud,
        data=b'{"package":"hello-vps-api","tag":"main"}',
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {oidc_jwt}"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = json.loads(resp.read().decode())
    assert body.get("ok") is True and body.get("enqueued") == 1, body
    # owner mismatch → authenticated but no enqueue
    other = sign_jwt_rs256(
        {"alg": "RS256", "typ": "JWT", "kid": "test1"},
        {"iss": iss, "aud": hook_aud, "exp": now + 300, "iat": now, "repository_owner": "someone-else"},
        str(kdir / "key.pem"),
    )
    req = urllib.request.Request(
        hook_aud,
        data=b'{"package":"hello-vps-api","tag":"main"}',
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {other}"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = json.loads(resp.read().decode())
    assert body.get("ok") is True and body.get("enqueued") == 0, body
finally:
    proc2.terminate()
    try:
        proc2.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc2.kill()
print("oidc webhook ok")
PY

# Queue seriality smoke
export VIBED_HOME="${TMPDIR:-/tmp}/vibed-q-$$"
# shellcheck source=/dev/null
source lib/update_queue.sh
vibed_enqueue_update "a" "api" "/tmp/x" "img:1" "test"
vibed_enqueue_update "a" "api" "/tmp/x" "img:1" "test"
n="$(find "$(vibed_agent_home)/queue" -name '*.json' | wc -l)"
[[ "$n" -eq 1 ]] || { echo "expected 1 queued job, got $n" >&2; exit 1; }
rm -rf "$VIBED_HOME"

for f in \
  examples/vps-hello/package.sh \
  examples/vps-hello/build-images.sh \
  examples/vps-hello/test-dist.sh \
  examples/vps-hello/test/run.sh \
  examples/vps-hello/dist/install-api.sh \
  examples/vps-hello/dist/install-ui.sh \
  examples/vps-hello/dist/install-nodes.sh \
  examples/vps-hello/dist/install-gateway.sh \
  templates/host-gateway/start-gateway.sh \
  templates/host-gateway/setup-tls.sh \
  templates/update-agent/agent.sh \
  scripts/e2e-oidc-webhook.sh
do
  bash -n "$f"
done

echo "vibed-infra package validation OK"
