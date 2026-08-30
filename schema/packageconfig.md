# Product config schema (four files)

Product repos ship **templates only**. Run `package.sh` to generate committed `dist/`.

## templates/vibed-infra-config.yml

```yaml
name: my-product
version: 1
templates:
  api: api-config.yaml
  ui: ui-config.yaml
  nodes: nodes-config.yaml
network:
  edge: vps-edge          # shared host edge (default if omitted)
autoUpdate:
  api: { enabled: false, intervalMin: 30, offset: 0 }
  ui: { enabled: false, intervalMin: 20, offset: 15 }
  nodes: { enabled: false, intervalMin: 30, offset: 10 }
  gateway: { enabled: false, intervalMin: 20, offset: 20 }
gateway:
  publicIp: 203.0.113.10    # VPS IPv4 — baked into dist/DNS-SKILL.md
  tlsEmail: ops@example.com # Let’s Encrypt account email (host setup-tls)
  nginxImage: nginx:alpine
  sites:
    - host: app.example.com
      aliases: [www.app.example.com]
      healthPath: /api/health
      createPath: /api/items
      tlsCertDir: /etc/letsencrypt/live/app.example.com
```

Defaults: containers `{name}-api` / `{name}-ui` / `{name}-worker`; host gateway container `vps-gateway`.

## dist/ (generated)

| Path | Purpose |
|------|---------|
| `install-*.sh` | wget entrypoints |
| `DNS-SKILL.md` | Paste into AU browser agent; includes domains + `publicIp` when set |
| `packageconfig.yaml` | compiled config |
| `start-*.sh` / `update-*.sh` | lifecycle |
| `.env.*.example` | includes `PERSIST_LOG_DIR`, prune flags |

Gateway install writes `$GATEWAY_HOME/apps/{name}/sites.conf` (host-extension mode).

## Auto-update

When `*_AUTO_UPDATE=1`, cron **enqueues** into the machine update-agent (serial pulls). Fallback: direct `update-*.sh` if agent missing. After update: dangling image prune (`DOCKER_AUTO_PRUNE`).

## Persist logs

`PERSIST_LOG_DIR` per role. See [`skills/persist-logs/SKILL.md`](../skills/persist-logs/SKILL.md).

## Environment (install)

| Variable | Meaning |
|----------|---------|
| `GATEWAY_HOME` | Host gateway (default `~/services/gateway`) |
| `VIBED_HOME` | `~/services/vibed-infra` |
| `GATEWAY_PUBLIC_IP` / `TLS_EMAIL` / `TLS_MODE` | Host TLS (`setup-tls.sh`) |
| `PACKAGER_RAW` / `PRODUCT_RAW` / `PACKAGECONFIG_URL` | as before |
| `INFRA_PROFILE` | `api`, `ui`, `nodes`, `gateway` |
