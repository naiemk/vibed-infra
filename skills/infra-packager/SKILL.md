---
name: infra-packager
description: >-
  Wire a new product to the infra VPS packager: four YAML configs, package.sh →
  committed dist/, Docker images, GHCR OIDC pulls, and CI. Use when adding
  Backend/UI/worker deploy to a repo or migrating from ad-hoc install scripts.
---

# Infra packager — onboard a product

## When to use

- New repo needs wget VPS install (backend + UI + workers + HTTPS gateway)
- Replacing hand-written install/start/update scripts with generated `dist/`

## Steps

1. **Depend on** [`vibed-infra`](https://www.npmjs.com/package/vibed-infra) or clone this repo for `package.sh`.

2. **Create** `templates/` with four files — see [`schema/packageconfig.md`](../../schema/packageconfig.md) and [`examples/vps-hello/templates/`](../../examples/vps-hello/templates/). Set `gateway.publicIp`, `gateway.tlsEmail`, and `gateway.sites[].host` for DNS-SKILL + HTTPS (those values are also the GHCR notify URLs).

3. **Add** a tiny product `package.sh`:

```bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGER="$(node -e "console.log(require('path').dirname(require.resolve('vibed-infra/package.json')))")"
exec bash "$PACKAGER/package.sh" --product "$ROOT" --out "$ROOT/dist"
```

4. **Images** — Dockerfiles in `app/`; tag `:local` for dev; GHCR `:main` for prod (names in `*-config.yaml`). Immediate VPS pull uses the reusable GHCR workflow with `id-token: write` — see infra-cicd and infra-update-agent. No extra GitHub secret.

5. **Package and commit** `dist/` (includes `DNS-SKILL.md` with domains + public IP):

```bash
./package.sh
git add dist && git commit && git push
```

6. **CI** — product repo: package drift check + GHCR build (notifies VPS). Packager repo: `npm test`, `oidc-webhook-e2e`, `test-dist.sh`, `npm run test:e2e-multi`.

7. **VPS** — DNS first (paste `dist/DNS-SKILL.md` into AU agent), then wget. Install registers the app with the update-agent so the next GHCR push can pull immediately:

```bash
wget -qO- .../dist/install-api.sh | bash
# edit .env, ./start-api.sh
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
wget -qO- .../dist/install-gateway.sh | bash   # bootstraps host + setup-tls.sh
# Re-issue TLS after host/IP change: cd ~/services/gateway && ./setup-tls.sh --force
```

## Rules

- Infra never parses app config keys — only image names, ports, volume paths, site hostnames, publicIp/tlsEmail.
- Never overwrite existing `.env` on re-install.
- Gateway container names in `gateway.sites[]` must match running API/UI container names on `network.edge`.
- UI is a separate profile; gateway is nginx-only and does not start the UI.
- Prefer Let's Encrypt via `gateway.tlsEmail`; use `TLS_MODE=lab` only for CI/lab.
- Product GHCR workflow must set `id-token: write` or the VPS will not get an immediate pull.
