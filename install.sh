#!/usr/bin/env bash
# Infra packager — single wget entrypoint.
#
#   wget -qO- $PACKAGER_RAW/install.sh | env INFRA_PROFILE=api PACKAGECONFIG_URL=... bash
#
# Product wrappers set PACKAGECONFIG_URL and INFRA_PROFILE.
set -euo pipefail

PACKAGER_RAW="${PACKAGER_RAW:-${INFRA_RAW:-https://raw.githubusercontent.com/naiemk/vibed-infra/main}}"
DEST="${INSTALL_DIR:-.}"
PROFILE="${INFRA_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --components)
      IFS=',' read -ra _comps <<<"$2"
      for c in "${_comps[@]}"; do
        case "$c" in
          app|backend|api) PROFILE=api; break ;;
          ui) PROFILE=ui; break ;;
          workers|nodes) PROFILE=nodes; break ;;
          gateway) PROFILE=gateway; break ;;
        esac
      done
      shift 2
      ;;
    --dest) DEST="$2"; shift 2 ;;
    -h|--help)
      echo "usage: install.sh [--profile api|ui|nodes|gateway] [--dest DIR]"
      echo "env: PACKAGECONFIG_URL PRODUCT_RAW PACKAGER_RAW INFRA_PROFILE INSTALL_DIR"
      exit 0
      ;;
    *) shift ;;
  esac
done

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# Bootstrap libs from packager (works when piped via wget|bash or local PACKAGER_RAW path).
INFRA_LIB="$DEST/.infra-lib"
mkdir -p "$INFRA_LIB"
_bootstrap_lib() {
  local src="$1" dest="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dest"
  else
    _fetch "${PACKAGER_RAW}/lib/$(basename "$dest")" "$dest"
  fi
}
_fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$out"; else wget -qO "$out" "$url"; fi
}
LOCAL_PACKAGER=0
if [[ "$PACKAGER_RAW" =~ ^/ ]] && [[ -d "$PACKAGER_RAW/lib" ]]; then
  LOCAL_PACKAGER=1
fi
for lib in fetch.sh env.sh prompt.sh tls.sh load_config.py generate.py host_gateway.sh update_queue.sh webhook.py github_oidc.py; do
  if [[ "$LOCAL_PACKAGER" == "1" ]]; then
    cp -f "${PACKAGER_RAW}/lib/${lib}" "${INFRA_LIB}/${lib}"
  else
    _fetch "${PACKAGER_RAW}/lib/${lib}" "${INFRA_LIB}/${lib}"
  fi
done
for lib in start.sh update.sh install-auto-update.sh; do
  if [[ "$LOCAL_PACKAGER" == "1" ]]; then
    cp -f "${PACKAGER_RAW}/${lib}" "${DEST}/${lib}"
  else
    _fetch "${PACKAGER_RAW}/${lib}" "${DEST}/${lib}"
  fi
  chmod +x "${DEST}/${lib}"
done

# shellcheck source=/dev/null
source "${INFRA_LIB}/fetch.sh"
# shellcheck source=/dev/null
source "${INFRA_LIB}/prompt.sh"
# shellcheck source=/dev/null
source "${INFRA_LIB}/tls.sh"
# shellcheck source=/dev/null
source "${INFRA_LIB}/host_gateway.sh"

cd "$DEST"

if [[ -z "$PROFILE" ]]; then
  PROFILE="$(infra_pick_profile)"
fi

PACKAGECONFIG_URL="${PACKAGECONFIG_URL:-${PACKAGE_CONFIG_URL:-}}"
if [[ -z "$PACKAGECONFIG_URL" ]]; then
  echo "Set PACKAGECONFIG_URL to the product packageconfig.yaml (URL or path)" >&2
  exit 1
fi
PC_LOCAL="$DEST/.packageconfig.yaml"
if [[ "$PACKAGECONFIG_URL" =~ ^/ ]]; then
  cp -f "$PACKAGECONFIG_URL" "$PC_LOCAL"
else
  infra_fetch "$PACKAGECONFIG_URL" "$PC_LOCAL"
fi

if [[ -z "${PRODUCT_RAW:-}" && -n "${ONCHAIN_INVOICE_RAW:-}" ]]; then
  echo "warning: ONCHAIN_INVOICE_RAW is deprecated; use PRODUCT_RAW" >&2
  PRODUCT_RAW="$ONCHAIN_INVOICE_RAW"
fi
if [[ -z "${PRODUCT_RAW:-}" ]]; then
  PRODUCT_RAW="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig
from pathlib import Path
print(load_packageconfig(Path('${PC_LOCAL}')).get('rawBase',''))
"
  )"
fi
if [[ -z "$PRODUCT_RAW" ]]; then
  echo "Set PRODUCT_RAW or packageconfig rawBase (product templates URL or path)" >&2
  exit 1
fi

echo "== infra install profile=$PROFILE dest=$DEST =="

_py_profile() {
  python3 -c "
import sys, json
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig, get_profile
from pathlib import Path
p = get_profile(load_packageconfig(Path('${PC_LOCAL}')), '${PROFILE}')
print(json.dumps(p))
"
}

PROF_JSON="$(_py_profile)"
ROLE="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('role','backend'))" "$PROF_JSON")"
START_SCRIPT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('startScript','start.sh'))" "$PROF_JSON")"
UPDATE_SCRIPT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('updateScript','update.sh'))" "$PROF_JSON")"
ENV_EXAMPLE="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]).get('templates') or {}; print(t.get('envExample','.env.example'))" "$PROF_JSON")"
CONFIG_FILE="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]).get('templates') or {}; print(t.get('config',''))" "$PROF_JSON")"
COMPOSE_TPL="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]).get('templates') or {}; print(t.get('compose',''))" "$PROF_JSON")"
COMPOSE_MAINNET="$(python3 -c "import json,sys; t=json.loads(sys.argv[1]).get('templates') or {}; print(t.get('composeMainnet',''))" "$PROF_JSON")"

cp -f "${INFRA_LIB}/env.sh" "$DEST/lib-env.sh"
mkdir -p "$DEST/lib"
cp -f "${INFRA_LIB}/load_config.py" "$DEST/lib/"
cp -f "${INFRA_LIB}/generate.py" "$DEST/lib/"

if [[ -n "$ENV_EXAMPLE" ]]; then
  infra_write_template "${PRODUCT_RAW}/${ENV_EXAMPLE}" "$DEST/${ENV_EXAMPLE}" 0
  cp -f "$DEST/${ENV_EXAMPLE}" "$DEST/.env.example"
fi
if [[ -n "$CONFIG_FILE" ]]; then
  infra_write_if_missing "${PRODUCT_RAW}/${CONFIG_FILE}" "$DEST/${CONFIG_FILE}" 0
  infra_write_template "${PRODUCT_RAW}/${CONFIG_FILE}" "$DEST/${CONFIG_FILE}" 0
fi
if [[ -n "$COMPOSE_TPL" ]]; then
  infra_write_if_missing "${PRODUCT_RAW}/${COMPOSE_TPL}" "$DEST/${COMPOSE_TPL}" 0
  infra_write_template "${PRODUCT_RAW}/${COMPOSE_TPL}" "$DEST/${COMPOSE_TPL}" 0
fi
if [[ -n "$COMPOSE_MAINNET" ]]; then
  infra_write_template "${PRODUCT_RAW}/${COMPOSE_MAINNET}" "$DEST/${COMPOSE_MAINNET}" 0
fi

# Generic infra compose templates — only when product did not supply compose in packageconfig.
case "$ROLE" in
  backend)
    if [[ -z "$COMPOSE_TPL" ]]; then
      infra_write_template "${PACKAGER_RAW}/templates/docker-compose.backend.yml" "$DEST/docker-compose.backend.yml" 0
    fi
    ;;
  ui)
    ;;
  workers)
    if [[ -z "$COMPOSE_TPL" ]]; then
      infra_write_template "${PACKAGER_RAW}/templates/docker-compose.workers.yml" "$DEST/docker-compose.workers.yml" 0
    fi
    ;;
  gateway)
    if [[ -z "$COMPOSE_MAINNET" && -z "$COMPOSE_TPL" ]]; then
      infra_write_template "${PACKAGER_RAW}/templates/docker-compose.gateway.yml" "$DEST/docker-compose.gateway.yml" 0
    fi
    ;;
esac

if [[ -n "$START_SCRIPT" && "$START_SCRIPT" != "start.sh" ]]; then
  infra_write_if_missing "${PRODUCT_RAW}/${START_SCRIPT}" "$DEST/${START_SCRIPT}" 1
  infra_write_template "${PRODUCT_RAW}/${START_SCRIPT}" "$DEST/${START_SCRIPT}" 1
fi
if [[ -n "$UPDATE_SCRIPT" && "$UPDATE_SCRIPT" != "update.sh" ]]; then
  infra_write_if_missing "${PRODUCT_RAW}/${UPDATE_SCRIPT}" "$DEST/${UPDATE_SCRIPT}" 1
  infra_write_template "${PRODUCT_RAW}/${UPDATE_SCRIPT}" "$DEST/${UPDATE_SCRIPT}" 1
fi

python3 -c "
import json, sys
extras = json.loads(sys.argv[1]).get('extras') or []
for e in extras:
    print(e)
" "$PROF_JSON" | while read -r extra; do
  [[ -n "$extra" ]] || continue
  infra_write_if_missing "${PRODUCT_RAW}/${extra}" "$DEST/${extra}" 1
  infra_write_template "${PRODUCT_RAW}/${extra}" "$DEST/${extra}" 1
done

if [[ "$ROLE" == "gateway" ]]; then
  PRODUCT_NAME="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig
from pathlib import Path
c = load_packageconfig(Path('${PC_LOCAL}'))
print(c.get('name') or 'app')
"
  )"
  GATEWAY_HOME="${GATEWAY_HOME:-$(vibed_gateway_home)}"
  export GATEWAY_HOME
  mkdir -p "$DEST/gateway/conf.d" "$DEST/lib"

  # Phase 1: bootstrap shared host gateway once
  vibed_bootstrap_host_gateway "$PACKAGER_RAW"
  if [[ "$LOCAL_PACKAGER" == "1" ]]; then
    cp -f "${PACKAGER_RAW}/lib/env.sh" "${GATEWAY_HOME}/lib-env.sh"
    cp -f "${PACKAGER_RAW}/lib/host_gateway.sh" "${GATEWAY_HOME}/lib/host_gateway.sh" 2>/dev/null || \
      mkdir -p "${GATEWAY_HOME}/lib" && cp -f "${PACKAGER_RAW}/lib/host_gateway.sh" "${GATEWAY_HOME}/lib/host_gateway.sh"
  fi

  # Phase 2: app extension — sites.conf under host apps/{name}/
  SITES_TMP="$DEST/gateway/sites.conf"
  python3 "${INFRA_LIB}/generate.py" "$PC_LOCAL" --profile "$PROFILE" --mode app -o "$SITES_TMP"
  META_TMP="$DEST/gateway/meta.json"
  python3 -c "
import json, sys
from pathlib import Path
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig, get_profile
c = load_packageconfig(Path('${PC_LOCAL}'))
p = get_profile(c, '${PROFILE}')
meta = {
  'name': c.get('name'),
  'installDir': '${DEST}',
  'sites': p.get('sites') or [],
  'images': c.get('images') or {},
}
Path('${META_TMP}').write_text(json.dumps(meta, indent=2) + '\n')
"
  vibed_install_app_sites "$PRODUCT_NAME" "$SITES_TMP" "$META_TMP"

  # Product install dir keeps thin wrappers that point at host gateway
  infra_write_if_missing "${PRODUCT_RAW}/gateway/nginx.conf" "$DEST/gateway/nginx.conf" 0
  cat >"$DEST/start-gateway.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export GATEWAY_HOME="${GATEWAY_HOME}"
# shellcheck source=/dev/null
source "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/.infra-lib/host_gateway.sh" 2>/dev/null \\
  || source "${GATEWAY_HOME}/lib/host_gateway.sh"
vibed_reload_or_start_gateway
EOF
  cat >"$DEST/update-gateway.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env
export GATEWAY_HOME="${GATEWAY_HOME}"
# Regenerate this app's sites and reload host (image update is host's update-gateway.sh)
if [[ -f .packageconfig.yaml ]]; then
  python3 "\${SCRIPT_DIR}/.infra-lib/generate.py" .packageconfig.yaml --profile gateway --mode app \\
    -o "\${GATEWAY_HOME}/apps/${PRODUCT_NAME}/sites.conf" 2>/dev/null \\
    || python3 "\${GATEWAY_HOME}/../vibed-infra/lib/generate.py" .packageconfig.yaml --profile gateway --mode app \\
    -o "\${GATEWAY_HOME}/apps/${PRODUCT_NAME}/sites.conf"
fi
# shellcheck source=/dev/null
source "\${SCRIPT_DIR}/.infra-lib/host_gateway.sh" 2>/dev/null || source "${GATEWAY_HOME}/lib/host_gateway.sh"
vibed_reload_or_start_gateway
EOF
  chmod +x "$DEST/start-gateway.sh" "$DEST/update-gateway.sh"
  # generate.py / host_gateway.sh already live in .infra-lib from bootstrap
  cp -f "${INFRA_LIB}/host_gateway.sh" "$DEST/.infra-lib/host_gateway.sh" 2>/dev/null || true

  # Ensure host network name is in product .env example path after copy
  echo "GATEWAY_HOME=${GATEWAY_HOME}" >>"$DEST/.env.example" 2>/dev/null || true
fi

if [[ ! -f "$DEST/.env" ]]; then
  cp "$DEST/.env.example" "$DEST/.env"
  echo "created: $DEST/.env"
else
  echo "exists: $DEST/.env"
fi

# Align product DOCKER_NETWORK with host edge when gateway/host exists
if vibed_host_gateway_ready 2>/dev/null; then
  HG="$(vibed_gateway_home)"
  if [[ -f "$HG/.env" ]]; then
    HOST_NET="$(grep -E '^DOCKER_NETWORK=' "$HG/.env" | head -1 | cut -d= -f2- || true)"
    if [[ -n "$HOST_NET" && -f "$DEST/.env" ]]; then
      if grep -q '^DOCKER_NETWORK=' "$DEST/.env"; then
        sed -i "s|^DOCKER_NETWORK=.*|DOCKER_NETWORK=${HOST_NET}|" "$DEST/.env"
      else
        echo "DOCKER_NETWORK=${HOST_NET}" >>"$DEST/.env"
      fi
      echo "joined host edge network: $HOST_NET"
    fi
  fi
fi

cat >"$DEST/.infra-profile" <<EOF
PROFILE=${PROFILE}
ROLE=${ROLE}
START_SCRIPT=${START_SCRIPT}
UPDATE_SCRIPT=${UPDATE_SCRIPT}
EOF

chmod +x "$DEST/${START_SCRIPT}" 2>/dev/null || true

# Ensure update-agent + persist-logs on first install (idempotent)
_install_update_agent() {
  local agent_packager="$PACKAGER_RAW"
  if [[ "$LOCAL_PACKAGER" != "1" ]]; then
    agent_packager="${DEST}/.infra-packager"
    mkdir -p "$agent_packager/lib" "$agent_packager/templates/update-agent"
    cp -f "${INFRA_LIB}/update_queue.sh" "$agent_packager/lib/update_queue.sh" 2>/dev/null || true
    cp -f "${INFRA_LIB}/webhook.py" "$agent_packager/lib/webhook.py" 2>/dev/null || true
    cp -f "${INFRA_LIB}/github_oidc.py" "$agent_packager/lib/github_oidc.py" 2>/dev/null || true
    for f in install-agent.sh agent.sh enqueue.sh webhook_server.py; do
      _fetch "${PACKAGER_RAW}/templates/update-agent/${f}" "$agent_packager/templates/update-agent/${f}" || true
    done
  fi
  if [[ -f "${agent_packager}/templates/update-agent/install-agent.sh" ]]; then
    chmod +x "$agent_packager/templates/update-agent/"*.sh 2>/dev/null || true
    PACKAGER_RAW="$agent_packager" VIBED_HOME="${VIBED_HOME:-}" bash "${agent_packager}/templates/update-agent/install-agent.sh" || true
  fi
}
_install_update_agent

# Register this install so GHCR notify can enqueue without waiting for cron
PRODUCT_NAME="${PRODUCT_NAME:-$(
  python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig
from pathlib import Path
print(load_packageconfig(Path('${PC_LOCAL}')).get('name') or 'app')
"
)}"
_REG_ROLE="$ROLE"
case "$ROLE" in
  backend) _REG_ROLE=api ;;
  workers) _REG_ROLE=nodes ;;
esac
# shellcheck source=/dev/null
if [[ -f "${INFRA_LIB}/update_queue.sh" ]]; then
  source "${INFRA_LIB}/update_queue.sh"
elif [[ -f "${PACKAGER_RAW}/lib/update_queue.sh" ]]; then
  source "${PACKAGER_RAW}/lib/update_queue.sh"
fi
if declare -F vibed_register_app >/dev/null 2>&1; then
  _env_val() {
    local key="$1"
    [[ -f "$DEST/.env" ]] || return 0
    grep -E "^${key}=" "$DEST/.env" 2>/dev/null | head -1 | cut -d= -f2-
  }
  _REG_IMAGE=""
  case "$_REG_ROLE" in
    api) _REG_IMAGE="$(_env_val BACKEND_IMAGE)" ;;
    ui) _REG_IMAGE="$(_env_val UI_IMAGE)" ;;
    nodes) _REG_IMAGE="$(_env_val WORKER_IMAGE)" ;;
    gateway) _REG_IMAGE="$(_env_val NGINX_IMAGE)" ;;
  esac
  vibed_register_app "$PRODUCT_NAME" "$_REG_ROLE" "$DEST" "$_REG_IMAGE" || true
  _HOOK_TOKEN="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from pathlib import Path
from load_config import load_packageconfig
try:
    from webhook import webhook_from_packageconfig
except ImportError:
    webhook_from_packageconfig = None
c = load_packageconfig(Path('${PC_LOCAL}'))
if webhook_from_packageconfig:
    print(webhook_from_packageconfig(c).get('token') or '')
else:
    print((c.get('webhook') or {}).get('token') or '')
"
  )"
  if [[ -n "${_HOOK_TOKEN}" ]]; then
    AGENT_HOME="$(vibed_agent_home 2>/dev/null || echo "${VIBED_HOME:-$HOME/services/vibed-infra}/update-agent")"
    mkdir -p "${AGENT_HOME}/tokens"
    printf '%s\n' "$_HOOK_TOKEN" >"${AGENT_HOME}/tokens/${PRODUCT_NAME}"
    echo "webhook token registered for ${PRODUCT_NAME}"
  fi
fi
if [[ -f "${PACKAGER_RAW}/templates/persist-logs/install-persist-logs.sh" ]]; then
  PACKAGER_RAW="$PACKAGER_RAW" VIBED_HOME="${VIBED_HOME:-}" bash "${PACKAGER_RAW}/templates/persist-logs/install-persist-logs.sh" || true
fi

INFRA_PROFILE="$PROFILE" ./install-auto-update.sh || true

if [[ "$ROLE" == "gateway" ]]; then
  # shellcheck source=/dev/null
  source "$DEST/lib-env.sh"
  load_dotenv "$DEST/.env"
  HG="$(vibed_gateway_home)"
  mkdir -p "$HG/certs" "$HG/certbot-www"

  # Propagate public IP / TLS email from packageconfig into host + product .env
  GW_PUBLIC_IP="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig, get_profile
from pathlib import Path
c = load_packageconfig(Path('${PC_LOCAL}'))
p = get_profile(c, '${PROFILE}')
print(p.get('publicIp') or '')
"
  )"
  GW_TLS_EMAIL="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig, get_profile
from pathlib import Path
c = load_packageconfig(Path('${PC_LOCAL}'))
p = get_profile(c, '${PROFILE}')
print(p.get('tlsEmail') or '')
"
  )"
  _patch_env() {
    local file="$1" key="$2" val="$3"
    [[ -n "$val" ]] || return 0
    [[ -f "$file" ]] || return 0
    if grep -q "^${key}=" "$file" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
      echo "${key}=${val}" >>"$file"
    fi
  }
  if [[ -f "$HG/.env" ]]; then
    _patch_env "$HG/.env" GATEWAY_PUBLIC_IP "${GATEWAY_PUBLIC_IP:-$GW_PUBLIC_IP}"
    _patch_env "$HG/.env" TLS_EMAIL "${TLS_EMAIL:-$GW_TLS_EMAIL}"
    # Product/install env can force lab (CI) without wiping host LE later
    if [[ -n "${TLS_MODE:-}" ]]; then
      _patch_env "$HG/.env" TLS_MODE "$TLS_MODE"
    fi
  fi
  _patch_env "$DEST/.env" GATEWAY_PUBLIC_IP "${GATEWAY_PUBLIC_IP:-$GW_PUBLIC_IP}"
  _patch_env "$DEST/.env" TLS_EMAIL "${TLS_EMAIL:-$GW_TLS_EMAIL}"

  # Collect domains for TLS_DOMAINS fallback if apps conf not parseable yet
  TLS_DOMAINS="$(
    python3 -c "
import sys
sys.path.insert(0, '${INFRA_LIB}')
from load_config import load_packageconfig, get_profile
from pathlib import Path
p = get_profile(load_packageconfig(Path('${PC_LOCAL}')), '${PROFILE}')
names=[]
for s in p.get('sites') or []:
    names.append(s['host'])
    names.extend(s.get('aliases') or [])
print(' '.join(names))
"
  )"
  export TLS_DOMAINS
  export GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-$GW_PUBLIC_IP}"
  export TLS_EMAIL="${TLS_EMAIL:-$GW_TLS_EMAIL}"

  if [[ -x "$HG/setup-tls.sh" ]]; then
    echo "Running host gateway TLS setup ..."
    (cd "$HG" && GATEWAY_HOME="$HG" TLS_DOMAINS="$TLS_DOMAINS" \
      GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}" \
      TLS_EMAIL="${TLS_EMAIL:-}" \
      TLS_MODE="${TLS_MODE:-}" \
      ./setup-tls.sh) || {
      echo "TLS setup did not complete — fix DNS then: cd $HG && ./setup-tls.sh --force" >&2
    }
  else
    echo "warning: $HG/setup-tls.sh missing — re-run gateway install to bootstrap" >&2
  fi
fi

echo ""
if [[ "$ROLE" == "gateway" ]]; then
  echo "Install complete. Host gateway: $(vibed_gateway_home)"
  echo "App sites: $(vibed_gateway_home)/apps/${PRODUCT_NAME:-app}/sites.conf"
  echo "TLS: cd $(vibed_gateway_home) && ./setup-tls.sh   # re-run if host/IP/domains change (--force)"
  echo "Start: cd $DEST && ./start-gateway.sh"
else
  echo "Install complete. Start: cd $DEST && ./${START_SCRIPT}"
fi
