#!/usr/bin/env bash
# Issue or refresh host gateway TLS when missing, forced, or domains/IP changed.
# Usage: ./setup-tls.sh [--force]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    -h|--help)
      echo "usage: $0 [--force]"
      echo "  Issues Let's Encrypt (TLS_EMAIL / TLS_MODE=letsencrypt) or lab self-signed certs."
      echo "  LE prefers host certbot when available (root or passwordless sudo);"
      echo "  otherwise uses docker run certbot/certbot (no sudo). PEMs land in ./certs/."
      echo "  Re-runs when certs missing, domains/IP changed vs .vibed-tls-state, or --force."
      exit 0
      ;;
  esac
done

# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

STATE_FILE="${SCRIPT_DIR}/.vibed-tls-state"
CERT_DIR="${SCRIPT_DIR}/certs"
CERTBOT_WWW="${CERTBOT_WWW:-${SCRIPT_DIR}/certbot-www}"
GATEWAY_NAME="${GATEWAY_NAME:-vps-gateway}"
mkdir -p "$CERT_DIR" "$CERTBOT_WWW"

patch_env_key() {
  local key="$1" val="$2" envfile="${3:-.env}"
  if grep -q "^${key}=" "$envfile" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$envfile"
  else
    echo "${key}=${val}" >>"$envfile"
  fi
}

collect_domains() {
  local domains=()
  local f line names n
  if [[ -d apps ]]; then
    for f in apps/*/sites.conf; do
      [[ -f "$f" ]] || continue
      while IFS= read -r line; do
        if [[ "$line" =~ server_name[[:space:]]+(.+)\; ]]; then
          names="${BASH_REMATCH[1]}"
          for n in $names; do
            [[ "$n" == "_" ]] && continue
            domains+=("$n")
          done
        fi
      done <"$f"
    done
  fi
  if [[ ${#domains[@]} -eq 0 && -n "${TLS_DOMAINS:-}" ]]; then
    # shellcheck disable=SC2206
    domains=(${TLS_DOMAINS})
  fi
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "No domains found under apps/*/sites.conf (and TLS_DOMAINS unset)" >&2
    return 1
  fi
  # unique sorted
  printf '%s\n' "${domains[@]}" | sort -u
}

domains_csv() {
  local d
  local out=""
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    out="${out:+$out,}${d}"
  done
  echo "$out"
}

read_state() {
  STATE_DOMAINS=""
  STATE_IP=""
  STATE_MODE=""
  [[ -f "$STATE_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_FILE" 2>/dev/null || true
  STATE_DOMAINS="${domains:-}"
  STATE_IP="${publicIp:-}"
  STATE_MODE="${mode:-}"
}

write_state() {
  local mode="$1" domains_csv="$2" ip="$3"
  cat >"$STATE_FILE" <<EOF
# Managed by setup-tls.sh — do not edit by hand
mode=${mode}
domains=${domains_csv}
publicIp=${ip}
issuedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

gateway_running() {
  docker inspect "$GATEWAY_NAME" >/dev/null 2>&1
}

issue_lab() {
  local primary="$1"
  shift
  local rest=("$@")
  local sans="DNS:${primary},DNS:localhost"
  local d
  for d in "${rest[@]}"; do
    sans="${sans},DNS:${d}"
  done
  if [[ -n "${GATEWAY_PUBLIC_IP:-}" ]]; then
    sans="${sans},IP:${GATEWAY_PUBLIC_IP}"
  fi
  echo "Issuing lab (self-signed) cert for: ${primary} ${rest[*]:-}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "${CERT_DIR}/privkey.pem" \
    -out "${CERT_DIR}/fullchain.pem" \
    -subj "/CN=${primary}" \
    -addext "subjectAltName=${sans}" \
    >/dev/null 2>&1
  chmod 644 "${CERT_DIR}/fullchain.pem"
  chmod 600 "${CERT_DIR}/privkey.pem"
  patch_env_key TLS_FULLCHAIN "${CERT_DIR}/fullchain.pem"
  patch_env_key TLS_PRIVKEY "${CERT_DIR}/privkey.pem"
  patch_env_key TLS_MODE lab
}

issue_letsencrypt() {
  local primary="$1"
  shift
  local all=("$primary" "$@")
  local email="${TLS_EMAIL:-}"
  if [[ -z "$email" ]]; then
    echo "TLS_EMAIL (or gateway.tlsEmail) required for Let's Encrypt" >&2
    return 1
  fi

  local LE_HOME="${LETSENCRYPT_HOME:-${SCRIPT_DIR}/letsencrypt}"
  local CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot}"
  mkdir -p "$LE_HOME" "$LE_HOME/work" "$LE_HOME/logs" "$CERT_DIR" "$CERTBOT_WWW"

  # Absolute webroot for docker bind mounts
  local CERTBOT_WWW_ABS="$CERTBOT_WWW"
  [[ "$CERTBOT_WWW_ABS" != /* ]] && CERTBOT_WWW_ABS="${SCRIPT_DIR}/${CERTBOT_WWW_ABS#./}"
  mkdir -p "$CERTBOT_WWW_ABS"

  local use_webroot=0
  if gateway_running; then
    use_webroot=1
  fi

  local domain_args=()
  local d
  for d in "${all[@]}"; do
    domain_args+=(-d "$d")
  done

  local base_args=(
    certonly
    --agree-tos
    --non-interactive
    --email "$email"
    --cert-name "$primary"
    "${domain_args[@]}"
  )
  if [[ "${CERTBOT_DRY_RUN:-0}" == "1" ]]; then
    base_args+=(--dry-run)
  fi

  local ran=0
  local host_can_run=0
  if command -v certbot >/dev/null 2>&1; then
    if [[ "$(id -u)" -eq 0 ]]; then
      host_can_run=1
    elif sudo -n true >/dev/null 2>&1; then
      host_can_run=1
    fi
  fi

  if [[ "$host_can_run" == "1" ]]; then
    local host_args=(
      "${base_args[@]}"
      --config-dir "$LE_HOME"
      --work-dir "$LE_HOME/work"
      --logs-dir "$LE_HOME/logs"
    )
    if [[ "$use_webroot" == "1" ]]; then
      echo "Gateway running — host certbot webroot ($CERTBOT_WWW_ABS)"
      host_args+=(--webroot -w "$CERTBOT_WWW_ABS")
    else
      echo "Gateway not running — host certbot standalone (port 80 must be free)"
      host_args+=(--standalone)
    fi
    local run_certbot=(certbot)
    if [[ "$(id -u)" -ne 0 ]]; then
      run_certbot=(sudo certbot)
    fi
    if "${run_certbot[@]}" "${host_args[@]}"; then
      ran=1
      # Best-effort: reclaim root-owned LE tree after sudo certbot
      if [[ "$(id -u)" -ne 0 ]]; then
        sudo -n chown -R "$(id -u):$(id -g)" "$LE_HOME" 2>/dev/null || true
      fi
    fi
  fi

  if [[ "$ran" != "1" && "$host_can_run" != "1" ]] && command -v docker >/dev/null 2>&1; then
    local docker_args=(
      run --rm
      -v "${LE_HOME}:/etc/letsencrypt"
    )
    local container_args=("${base_args[@]}")
    if [[ "$use_webroot" == "1" ]]; then
      echo "Gateway running — docker certbot webroot ($CERTBOT_WWW_ABS)"
      docker_args+=(-v "${CERTBOT_WWW_ABS}:/var/www/certbot")
      container_args+=(--webroot -w /var/www/certbot)
    else
      echo "Gateway not running — docker certbot standalone (-p 80:80)"
      docker_args+=(-p 80:80)
      container_args+=(--standalone)
    fi
    if docker "${docker_args[@]}" "$CERTBOT_IMAGE" "${container_args[@]}"; then
      ran=1
    fi
  fi

  if [[ "$ran" != "1" ]]; then
    if [[ "$host_can_run" != "1" ]] && ! command -v docker >/dev/null 2>&1; then
      cat <<EOF >&2
Neither usable host certbot nor docker found.
Install Docker (preferred for non-root), or certbot with sudo, or set TLS_MODE=lab.
EOF
    else
      cat <<EOF >&2

Let's Encrypt failed (often DNS not pointing here yet).
1. Paste dist/DNS-SKILL.md into your AU DNS agent (or create the A records yourself).
2. dig +short ${primary}  # must return this VPS public IP
3. Re-run: cd ${SCRIPT_DIR} && ./setup-tls.sh --force

EOF
    fi
    return 1
  fi

  # Dry-run does not write live PEMs
  if [[ "${CERTBOT_DRY_RUN:-0}" == "1" ]]; then
    echo "certbot dry-run succeeded (no PEMs written)"
    return 0
  fi

  local live="${LE_HOME}/live/${primary}"
  if [[ ! -f "${live}/fullchain.pem" || ! -f "${live}/privkey.pem" ]]; then
    echo "certbot succeeded but ${live} PEMs missing" >&2
    return 1
  fi
  cp -L "${live}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
  cp -L "${live}/privkey.pem" "${CERT_DIR}/privkey.pem"
  chmod 644 "${CERT_DIR}/fullchain.pem"
  chmod 600 "${CERT_DIR}/privkey.pem"
  patch_env_key TLS_FULLCHAIN "${CERT_DIR}/fullchain.pem"
  patch_env_key TLS_PRIVKEY "${CERT_DIR}/privkey.pem"
  patch_env_key TLS_MODE letsencrypt
  patch_env_key TLS_EMAIL "$email"
}

# --- main ---
mapfile -t DOMAIN_LIST < <(collect_domains)
PRIMARY="${DOMAIN_LIST[0]}"
REST=("${DOMAIN_LIST[@]:1}")
DESIRED_CSV="$(printf '%s\n' "${DOMAIN_LIST[@]}" | domains_csv)"
PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"

# Sync IP/email from env into .env for persistence
[[ -n "$PUBLIC_IP" ]] && patch_env_key GATEWAY_PUBLIC_IP "$PUBLIC_IP"
[[ -n "${TLS_EMAIL:-}" ]] && patch_env_key TLS_EMAIL "$TLS_EMAIL"

read_state
NEED=0
TLS_FULLCHAIN_PATH="${TLS_FULLCHAIN:-${CERT_DIR}/fullchain.pem}"
TLS_PRIVKEY_PATH="${TLS_PRIVKEY:-${CERT_DIR}/privkey.pem}"
# Resolve relative paths
[[ "$TLS_FULLCHAIN_PATH" != /* ]] && TLS_FULLCHAIN_PATH="${SCRIPT_DIR}/${TLS_FULLCHAIN_PATH#./}"
[[ "$TLS_PRIVKEY_PATH" != /* ]] && TLS_PRIVKEY_PATH="${SCRIPT_DIR}/${TLS_PRIVKEY_PATH#./}"

if [[ "$FORCE" == "1" ]]; then
  NEED=1
  echo "setup-tls: --force"
elif [[ ! -f "$TLS_FULLCHAIN_PATH" || ! -f "$TLS_PRIVKEY_PATH" ]]; then
  NEED=1
  echo "setup-tls: certificate files missing"
elif [[ "$STATE_DOMAINS" != "$DESIRED_CSV" ]]; then
  NEED=1
  echo "setup-tls: domains changed (was '${STATE_DOMAINS:-none}' → '${DESIRED_CSV}')"
elif [[ -n "$PUBLIC_IP" && "$STATE_IP" != "$PUBLIC_IP" ]]; then
  NEED=1
  echo "setup-tls: public IP changed (was '${STATE_IP:-none}' → '${PUBLIC_IP}')"
fi

if [[ "$NEED" == "0" ]]; then
  echo "setup-tls: OK (certs cover ${DESIRED_CSV})"
  exit 0
fi

MODE="${TLS_MODE:-}"
if [[ -z "$MODE" ]]; then
  if [[ -n "${TLS_EMAIL:-}" ]]; then
    MODE=letsencrypt
  else
    MODE=lab
  fi
fi

case "$MODE" in
  letsencrypt|le|prod|production)
    issue_letsencrypt "$PRIMARY" "${REST[@]}"
    write_state letsencrypt "$DESIRED_CSV" "$PUBLIC_IP"
    ;;
  lab|dev|selfsigned)
    issue_lab "$PRIMARY" "${REST[@]}"
    write_state lab "$DESIRED_CSV" "$PUBLIC_IP"
    ;;
  *)
    echo "Unknown TLS_MODE=$MODE (use lab or letsencrypt)" >&2
    exit 1
    ;;
esac

# Reload gateway if already running so new PEMs / SANs apply
if gateway_running && [[ -x ./reload-gateway.sh ]]; then
  echo "Reloading host gateway with new certs ..."
  ./reload-gateway.sh || true
fi

echo "setup-tls: done (mode=${MODE}, domains=${DESIRED_CSV})"
