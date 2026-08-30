#!/usr/bin/env bash
# Host / shared gateway helpers. Sourced by install.sh and start scripts.
# shellcheck shell=bash

vibed_gateway_home() {
  if [[ -n "${GATEWAY_HOME:-}" ]]; then
    echo "$GATEWAY_HOME"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    echo "${HOME}/services/gateway"
    return 0
  fi
  echo "/var/lib/vibed/gateway"
}

vibed_home() {
  if [[ -n "${VIBED_HOME:-}" ]]; then
    echo "$VIBED_HOME"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    echo "${HOME}/services/vibed-infra"
    return 0
  fi
  echo "/var/lib/vibed"
}

vibed_host_gateway_ready() {
  local home
  home="$(vibed_gateway_home)"
  [[ -f "${home}/.vibed-host-gateway" ]]
}

vibed_bootstrap_host_gateway() {
  local packager="${1:?packager root or URL}"
  local home
  home="$(vibed_gateway_home)"
  mkdir -p "$home/gateway/conf.d" "$home/apps" "$home/certs" "$home/certbot-www"

  _hg_fetch() {
    local rel="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [[ "$packager" =~ ^/ ]]; then
      cp -f "${packager}/${rel}" "$dest"
    else
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${packager}/${rel}" -o "$dest"
      else
        wget -qO "$dest" "${packager}/${rel}"
      fi
    fi
  }

  # Always refresh setup-tls (idempotent re-install / multi-app)
  _hg_fetch "templates/host-gateway/setup-tls.sh" "$home/setup-tls.sh"
  chmod +x "$home/setup-tls.sh"

  if [[ -f "${home}/.vibed-host-gateway" ]]; then
    echo "host gateway already present: $home"
    return 0
  fi

  echo "bootstrapping host gateway at $home"

  _hg_fetch "templates/host-gateway/gateway/nginx.conf" "$home/gateway/nginx.conf"
  _hg_fetch "templates/host-gateway/gateway/conf.d/00-default.conf" "$home/gateway/conf.d/00-default.conf"
  _hg_fetch "templates/host-gateway/.env.example" "$home/.env.example"
  _hg_fetch "templates/host-gateway/start-gateway.sh" "$home/start-gateway.sh"
  _hg_fetch "templates/host-gateway/reload-gateway.sh" "$home/reload-gateway.sh"
  _hg_fetch "templates/host-gateway/update-gateway.sh" "$home/update-gateway.sh"
  _hg_fetch "lib/env.sh" "$home/lib-env.sh"
  chmod +x "$home/start-gateway.sh" "$home/reload-gateway.sh" "$home/update-gateway.sh"

  if [[ ! -f "$home/.env" ]]; then
    cp "$home/.env.example" "$home/.env"
  fi
  mkdir -p "$home/lib"
  _hg_fetch "lib/host_gateway.sh" "$home/lib/host_gateway.sh"

  echo "1" >"${home}/.vibed-host-gateway"
  echo "bootstrapped host gateway: $home"
}

vibed_install_app_sites() {
  local app_name="$1"
  local sites_conf_src="$2"
  local meta_json="${3:-}"
  local home
  home="$(vibed_gateway_home)"
  local app_dir="${home}/apps/${app_name}"
  mkdir -p "$app_dir"
  cp -f "$sites_conf_src" "${app_dir}/sites.conf"
  if [[ -n "$meta_json" && -f "$meta_json" ]]; then
    cp -f "$meta_json" "${app_dir}/meta.json"
  fi
  echo "installed app sites: ${app_dir}/sites.conf"
}

vibed_reload_or_start_gateway() {
  local home
  home="$(vibed_gateway_home)"
  # shellcheck source=/dev/null
  [[ -f "$home/lib-env.sh" ]] && source "$home/lib-env.sh"
  # shellcheck disable=SC1091
  [[ -f "$home/.env" ]] && load_dotenv "$home/.env" 2>/dev/null || true
  local name="${GATEWAY_NAME:-vps-gateway}"
  if docker inspect "$name" >/dev/null 2>&1; then
    if [[ -x "$home/reload-gateway.sh" ]]; then
      (cd "$home" && ./reload-gateway.sh)
    else
      (cd "$home" && ./start-gateway.sh)
    fi
  else
    (cd "$home" && ./start-gateway.sh)
  fi
}
