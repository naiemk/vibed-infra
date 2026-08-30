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
| `~/services/vibed-infra/update-agent` | Serial pull queue + optional GHCR webhook |
| `~/services/vibed-infra/persist-logs` | Per-app WALs + optional R2/S3 ship |

Auto-update cron **enqueues** work; the agent processes one job at a time. After a GHCR push, the reusable image workflow mints a GitHub Actions OIDC JWT and notifies `https://{domain}/_vibed/hooks/ghcr` (fallback `http://{publicIp}/…`) so the pull does not wait for cron. Updates prune dangling images (`DOCKER_AUTO_PRUNE=1`).

## Layout

| Path | Purpose |
|------|---------|
| `package.sh` / `lib/package.py` | Build `dist/` |
| `templates/host-gateway/` | Shared gateway skeleton |
| `templates/update-agent/` | Queue agent + webhook |
| `templates/persist-logs/` | Shipper install |
| `lib/persistlog/` | Python append / seal / replay |
| `skills/` | system-gateway, infra-update-agent, persist-logs, dns-configure |

## Environment

| Variable | Meaning |
|----------|---------|
| `GATEWAY_HOME` | Host gateway dir (default `~/services/gateway`) |
| `VIBED_HOME` | Machine vibed root (default `~/services/vibed-infra`) |
| `GATEWAY_PUBLIC_IP` | VPS IPv4 (from `gateway.publicIp`) |
| `TLS_EMAIL` / `TLS_MODE` | Let’s Encrypt email; `lab` or `letsencrypt` |
| `PERSIST_LOG_DIR` | Per-service event log dir |
| `DOCKER_AUTO_PRUNE` | Prune dangling images after update (default on) |

## Tests

```bash
npm test
npm run test:dist
npm run test:e2e-multi   # two apps, localhost wget|bash, shared host gateway
```

## Publishing

Merge to `main` runs Publish npm (minor bump). Set `NPM_TOKEN`. Ordinary PRs run CI only.
