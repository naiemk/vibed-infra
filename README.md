# vibed-infra

Product-agnostic VPS packager: **`package.sh`** builds committed **`dist/`** for wget install. One **host gateway** serves many apps; a **serial update agent** pulls images without overload; **persist-logs** enable event-sourced recovery; **`dist/DNS-SKILL.md`** configures DNS via an AU browser agent.

Published on npm as **`vibed-infra`**.

## Product maintainer flow

| File | Purpose |
|------|---------|
| `vibed-infra-config.yml` | Name, templates, `network.edge`, `gateway.publicIp` / `tlsEmail` / `sites[]`, auto-update |
| `api-config.yaml` / `ui-config.yaml` / `nodes-config.yaml` | Images + opaque config |

```bash
./package.sh
git add dist && git commit && git push
# Copy dist/DNS-SKILL.md into AU agent (domains + publicIp already filled when configured)
```

## Operator flow (VPS)

Non-root agent prep (SSH, Docker group, uid 1000 data dirs): [`skills/agent-vps-prep/SKILL.md`](skills/agent-vps-prep/SKILL.md).

```bash
# 1) DNS — paste dist/DNS-SKILL.md into AU browser agent
# 2) App roles
wget -qO- .../dist/install-api.sh | bash
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
# 3) Host gateway + TLS (setup-tls.sh; re-run with --force if host/IP changes)
wget -qO- .../dist/install-gateway.sh | bash
```

| Profile | Role |
|---------|------|
| `api` / `ui` / `nodes` | Join shared `vps-edge` |
| `gateway` | Host nginx + `apps/{name}/sites.conf` + HTTPS via `~/services/gateway/setup-tls.sh` |

Multi-app: further products’ `install-gateway.sh` only add `apps/{other}/sites.conf`, refresh TLS SANs, and reload — no second 80/443 bind.

## Machine services (installed once)

| Path | Purpose |
|------|---------|
| `~/services/gateway` | Host nginx (`GATEWAY_HOME`) |
| `~/services/vibed-infra/update-agent` | Serial pull queue; GHCR notify via GitHub Actions OIDC |
| `~/services/vibed-infra/persist-logs` | Per-app WALs + optional R2/S3 ship |

## Image updates (docker pull)

Install registers each role in the machine **update-agent**. Two paths enqueue work; the agent runs **one pull at a time** (`update-*.sh` is digest-gated — no restart if the image digest is unchanged):

1. **Immediate** — push `:main` with the reusable GHCR workflow (`id-token: write`). CI mints an OIDC JWT and POSTs `https://{site host}/_vibed/hooks/ghcr` (fallback `http://{publicIp}/…`). No GitHub webhook UI or `VIBED_WEBHOOK_SECRET`.
2. **Cron** — if `*_AUTO_UPDATE=1`, periodic enqueue (backup if notify is missed).

See [`skills/infra-update-agent/SKILL.md`](skills/infra-update-agent/SKILL.md). After a successful update, dangling images are pruned (`DOCKER_AUTO_PRUNE=1`).

## Layout

| Path | Purpose |
|------|---------|
| `package.sh` / `lib/package.py` | Build `dist/` |
| `templates/host-gateway/` | Shared gateway skeleton |
| `templates/update-agent/` | Queue agent + webhook |
| `templates/persist-logs/` | Shipper install |
| `lib/persistlog/` | Python append / seal / replay |
| `skills/` | system-gateway, agent-vps-prep, infra-update-agent, infra-cicd, infra-packager, persist-logs, dns-configure |

## Environment

| Variable | Meaning |
|----------|---------|
| `GATEWAY_HOME` | Host gateway dir (default `~/services/gateway`) |
| `VIBED_HOME` | Machine vibed root (default `~/services/vibed-infra`) |
| `VIBED_UPDATE_AGENT` | Override update-agent dir (default `$VIBED_HOME/update-agent`) |
| `GATEWAY_PUBLIC_IP` | VPS IPv4 (from `gateway.publicIp`) |
| `TLS_EMAIL` / `TLS_MODE` | Let’s Encrypt email; `lab` or `letsencrypt` (docker certbot → `./certs` PEMs; optional `CERTBOT_IMAGE` / `LETSENCRYPT_HOME`) |
| `PERSIST_LOG_DIR` | Per-service event log dir |
| `DOCKER_AUTO_PRUNE` | Prune dangling images after update (default on) |

## Tests

```bash
npm test
npm run test:oidc       # real GitHub OIDC mint; skips locally unless ACTIONS_ID_TOKEN_* set
npm run test:dist
npm run test:e2e-multi   # two apps, localhost wget|bash, shared host gateway
```

## Publishing

Merge to `main` runs Publish npm (minor bump). Set `NPM_TOKEN`. Ordinary PRs run CI only.
