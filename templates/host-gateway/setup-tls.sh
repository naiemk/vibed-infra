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
  if ! command -v certbot >/dev/null 2>&1; then
    echo "certbot not found — install certbot, or set TLS_MODE=lab for self-signed" >&2
    return 1
  fi
  local args=(certonly --non-interactive --agree-tos --email "$email" --cert-name "$primary")
  local d
  for d in "${all[@]}"; do
    args+=(-d "$d")
  done
  if gateway_running; then
    echo "Gateway running — certbot webroot ($CERTBOT_WWW)"
    args+=(--webroot -w "$CERTBOT_WWW")
  else
    echo "Gateway not running — certbot standalone (port 80 must be free)"
    args+=(--standalone)
  fi
  if [[ "${CERTBOT_DRY_RUN:-0}" == "1" ]]; then
    args+=(--dry-run)
  fi
  if ! sudo certbot "${args[@]}"; then
    cat <<EOF >&2

Let's Encrypt failed (often DNS not pointing here yet).
1. Paste dist/DNS-SKILL.md into your AU DNS agent (or create the A records yourself).
2. dig +short ${primary}  # must return this VPS public IP
3. Re-run: cd ${SCRIPT_DIR} && ./setup-tls.sh --force

EOF
    return 1
  fi
  local live="/etc/letsencrypt/live/${primary}"
  if [[ ! -f "${live}/fullchain.pem" || ! -f "${live}/privkey.pem" ]]; then
    echo "certbot succeeded but ${live} PEMs missing" >&2
    return 1
  fi
  patch_env_key TLS_FULLCHAIN "${live}/fullchain.pem"
  patch_env_key TLS_PRIVKEY "${live}/privkey.pem"
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
