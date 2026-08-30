---
name: system-gateway
description: >-
  Configure a shared host HTTPS gateway with per-app nginx extensions so multiple
  vibed-infra products share one VPS (ports 80/443) without hand-editing nginx.
---

# System-wide host gateway (multi-app)

Fresh VPS as non-root agent: see [agent-vps-prep](../agent-vps-prep/SKILL.md).

## Model

```
~/services/gateway/                 # GATEWAY_HOME — once per machine
  .vibed-host-gateway               # marker
  setup-tls.sh                      # issue/refresh certs (LE or lab)
  .vibed-tls-state                  # domains + publicIp fingerprint
  start-gateway.sh / reload-gateway.sh
  gateway/nginx.conf                # includes conf.d + apps/*/sites.conf
  gateway/conf.d/00-default.conf    # ACME + HTTP→HTTPS + /_vibed/hooks/
  apps/
    hello-vps/sites.conf            # generated from product gateway.sites[]
    other-app/sites.conf
```

- Shared Docker network: **`vps-edge`** (from host `.env`).
- Only the **host** binds 80/443. Product `install-gateway.sh` bootstraps host if missing, then installs/updates that product’s `apps/{name}/sites.conf`, runs **`setup-tls.sh`**, and can reload.
- UI and API are separate installs; they must join `DOCKER_NETWORK=vps-edge`.

## Operator flow

1. Set DNS from **`dist/DNS-SKILL.md`** (domains + `gateway.publicIp`).
2. Install gateway (sets up TLS when possible):

```bash
wget -qO- .../dist/install-gateway.sh | bash
cd ~/…/gateway-install && ./start-gateway.sh

# second product on same VPS — adds apps/other/sites.conf and re-runs setup-tls (new SANs)
wget -qO- .../other/dist/install-gateway.sh | bash
```

Override location: `GATEWAY_HOME=/path/to/gateway`.

## TLS

Config (product `vibed-infra-config.yml`):

- `gateway.publicIp` — baked into DNS-SKILL
- `gateway.tlsEmail` — Let’s Encrypt account email → `TLS_MODE=letsencrypt` on setup
- Host `.env`: `TLS_EMAIL`, `GATEWAY_PUBLIC_IP`, `TLS_MODE=lab|letsencrypt`

```bash
cd ~/services/gateway
./setup-tls.sh          # no-op if certs already cover current domains/IP
./setup-tls.sh --force  # re-issue after host or IP change
```

- **Production:** `setup-tls.sh` issues Let’s Encrypt via docker `certbot/certbot` by default (config under `$GATEWAY_HOME/letsencrypt`, PEMs installed into `$GATEWAY_HOME/certs/` — direct `cp` when readable, else alpine container copy+chown for root-owned `live/`). No sudo required when Docker is available. Host certbot + sudo still preferred when present (same `--config-dir` under gateway home). Webroot if gateway is up, else standalone. On failure, fix DNS then re-run `setup-tls.sh`.
- **Lab/CI:** `TLS_MODE=lab` → multi-SAN self-signed under `./certs/`.

## Webhook path (immediate docker pull)

Host `00-default.conf` (HTTP) and each app `sites.conf` (HTTPS) proxy `/_vibed/hooks/` to the update-agent on `host.docker.internal:19200`. After a GHCR `:main` push, CI POSTs a GitHub Actions OIDC JWT to `/_vibed/hooks/ghcr` — see infra-update-agent. Do not expose port 19200 on the public firewall.

## Pitfalls

- Operator user / Docker / uid 1000 data dirs: [agent-vps-prep](../agent-vps-prep/SKILL.md).
- Do not run a second standalone nginx on 80/443.
- Container names in `sites.conf` must match running API/UI names on `vps-edge`.
- After cert renewal or `setup-tls.sh`, reload happens automatically when the gateway container is already running.
