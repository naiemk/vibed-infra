---
name: system-gateway
description: >-
  Configure a system-wide HTTPS gateway on one VPS for multiple products/domains.
  Use when several infra-packaged projects share one host, edge network, and Let's Encrypt.
---

# System-wide gateway (multi-project)

## Model

- One **gateway** install dir per host: nginx on ports 80/443 (`install-gateway.sh` from product `dist/`).
- Each product **API** + **UI** join the same Docker network (`network.edge` in `vibed-infra-config.yml`).
- Gateway `gateway.sites[]` lists vhosts → generated `gateway/conf.d/domains.conf` on install.

## Steps

1. Pick shared network: `DOCKER_NETWORK=vps-edge` in every product `.env`.

2. Install APIs/UIs with distinct container names (defaults: `{name}-api`, `{name}-ui`).

3. Install gateway once:

```bash
wget -qO- .../dist/install-gateway.sh | bash
```

4. Ensure `gateway.sites[]` `backend` / `ui` match running container names (re-run `./package.sh` if you rename containers).

5. **TLS** — lab: `./gen-dev-certs.sh` from `dist/`, set paths in gateway `.env`. Production:

```bash
sudo certbot certonly --standalone -d app.example.com
```

Set `TLS_FULLCHAIN` / `TLS_PRIVKEY` in gateway `.env`, then `./start-gateway.sh` (reloads certs into the gateway volume).

6. **Auto-update** — stagger cron: API :00, UI :15, workers :10, gateway :20 (infra defaults). Update scripts prune dangling images afterward (`DOCKER_AUTO_PRUNE=1`).

## Dual-domain on one host

List multiple entries under `gateway.sites[]` in `vibed-infra-config.yml`. See [`examples/vps-hello/templates/vibed-infra-config.yml`](../../examples/vps-hello/templates/vibed-infra-config.yml).

## Pitfalls

- API must listen on a container name resolvable by nginx (`hello-vps-api:8080`, not `localhost`).
- Do not bind host port 443 twice — only gateway publishes 443.
- Gateway does not start UI; install UI separately before gateway.
- Re-run `./start-gateway.sh` after cert renewal so nginx picks up new cert files.
