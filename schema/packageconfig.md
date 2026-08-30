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
      tlsCertDir: ./certs  # host gateway PEMs; legacy /etc/letsencrypt/... paths ignored in .env.gateway.example
```

Defaults: containers `{name}-api` / `{name}-ui` / `{name}-worker`; host gateway container `vps-gateway`.

Compiled `packageconfig.yaml` also includes `webhook.url` / `fallbackUrl` (from `publicIp` + first `sites[].host`). After a default-branch image push, the reusable GHCR workflow mints a GitHub Actions OIDC JWT and POSTs to those URLs — no GitHub webhook UI and no extra secrets. `webhook.token` remains for local curl.

## dist/ (generated)

| Path | Purpose |
|------|---------|
| `install-*.sh` | wget entrypoints |
| `notify-vps-pull.py` | GHCR workflow: mint OIDC JWT and POST webhook URLs from `webhook:` |
| `DNS-SKILL.md` | Paste into AU browser agent; includes domains + `publicIp` when set |
| `packageconfig.yaml` | compiled config |
| `start-*.sh` / `update-*.sh` | lifecycle |
| `.env.*.example` | includes `PERSIST_LOG_DIR`, prune flags |

Gateway install writes `$GATEWAY_HOME/apps/{name}/sites.conf` (host-extension mode).

## Auto-update and docker pull

Install registers each role with the machine **update-agent**. Pulls are serial and digest-gated (`update-*.sh`).

- **Immediate:** reusable GHCR workflow on the default branch mints a GitHub Actions OIDC JWT and POSTs `https://{host}/_vibed/hooks/ghcr` (fallback `http://{publicIp}/_vibed/hooks/ghcr`). Caller needs `id-token: write`. See [`skills/infra-update-agent/SKILL.md`](../skills/infra-update-agent/SKILL.md).
- **Cron:** when `*_AUTO_UPDATE=1`, cron enqueues on an interval (backup if notify is missed). Fallback: direct `update-*.sh` if the agent is missing.
- After update: dangling image prune (`DOCKER_AUTO_PRUNE`).

`webhook.token` in compiled packageconfig is only for local curl; CI does not need `VIBED_WEBHOOK_SECRET`.

## Persist logs

`PERSIST_LOG_DIR` per role. See [`skills/persist-logs/SKILL.md`](../skills/persist-logs/SKILL.md).

## Environment (install)

| Variable | Meaning |
|----------|---------|
| `GATEWAY_HOME` | Host gateway (default `~/services/gateway`) |
| `VIBED_HOME` | `~/services/vibed-infra` |
| `VIBED_UPDATE_AGENT` | Override update-agent dir (default `$VIBED_HOME/update-agent`) |
| `GATEWAY_PUBLIC_IP` / `TLS_EMAIL` / `TLS_MODE` | Host TLS (`setup-tls.sh`) |
| `PACKAGER_RAW` / `PRODUCT_RAW` / `PACKAGECONFIG_URL` | as before |
| `INFRA_PROFILE` | `api`, `ui`, `nodes`, `gateway` |
