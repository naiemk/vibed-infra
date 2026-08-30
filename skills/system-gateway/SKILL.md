---
name: system-gateway
description: >-
  Configure a shared host HTTPS gateway with per-app nginx extensions so multiple
  vibed-infra products share one VPS (ports 80/443) without hand-editing nginx.
---

# System-wide host gateway (multi-app)

## Model

```
~/services/gateway/                 # GATEWAY_HOME — once per machine
  .vibed-host-gateway               # marker
  start-gateway.sh / reload-gateway.sh
  gateway/nginx.conf                # includes conf.d + apps/*/sites.conf
  gateway/conf.d/00-default.conf    # ACME + HTTP→HTTPS + /_vibed/hooks/
  apps/
    hello-vps/sites.conf            # generated from product gateway.sites[]
    other-app/sites.conf
```

- Shared Docker network: **`vps-edge`** (from host `.env`).
- Only the **host** binds 80/443. Product `install-gateway.sh` bootstraps host if missing, then installs/updates that product’s `apps/{name}/sites.conf` and reloads.
- UI and API are separate installs; they must join `DOCKER_NETWORK=vps-edge`.

## Operator flow

```bash
# first (or any) product — creates host + app extension
wget -qO- .../dist/install-gateway.sh | bash
cd ~/…/gateway-install && ./start-gateway.sh

# second product on same VPS — only adds apps/other/sites.conf
wget -qO- .../other/dist/install-gateway.sh | bash
```

Override location: `GATEWAY_HOME=/path/to/gateway`.

## TLS

Lab: `gen-dev-certs.sh` into `$GATEWAY_HOME/certs`. Production: certbot; set `TLS_FULLCHAIN` / `TLS_PRIVKEY` on the **host** `.env`, then `./reload-gateway.sh`.

## Webhook path

Host `00-default.conf` proxies `/_vibed/hooks/` to the update-agent on `host.docker.internal:19200` (see infra-update-agent skill).

## Pitfalls

- Do not run a second standalone nginx on 80/443.
- Container names in `sites.conf` must match running API/UI names on `vps-edge`.
- After cert renewal, reload the host gateway so nginx picks up new files.
