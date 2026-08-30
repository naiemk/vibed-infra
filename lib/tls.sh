# shellcheck shell=bash
# TLS / certbot helpers.

infra_tls_check() {
  local fullchain="$1"
  local privkey="$2"
  [[ -f "$fullchain" && -f "$privkey" ]]
}

infra_tls_suggest_certbot() {
  local domains=("$@")
  cat <<EOF

TLS certificates not found. From the host gateway directory, issue with:

  cd ~/services/gateway && ./setup-tls.sh --force

(setup-tls.sh uses docker certbot when available — no host certbot/sudo required —
or host certbot when installed. PEMs land in ./certs/.)

Or set TLS_MODE=lab for self-signed lab certs, then ./start.sh

EOF
}

infra_tls_offer_interactive() {
  local fullchain="$1"
  local privkey="$2"
  shift 2
  local domains=("$@")
  if infra_tls_check "$fullchain" "$privkey"; then
    return 0
  fi
  infra_tls_suggest_certbot "${domains[@]}"
  if [[ ! -t 0 ]]; then
    return 0
  fi
  local gw="${GATEWAY_HOME:-${HOME:-}/services/gateway}"
  read -r -p "Run setup-tls.sh in ${gw}? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES)
      if [[ -x "${gw}/setup-tls.sh" ]]; then
        (cd "$gw" && ./setup-tls.sh --force)
      else
        echo "setup-tls.sh not found at ${gw} — bootstrap the host gateway first" >&2
        return 1
      fi
      ;;
  esac
}
