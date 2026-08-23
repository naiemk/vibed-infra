---
name: infra-packager
description: >-
  Wire a new product to the infra VPS packager: four YAML configs, package.sh →
  committed dist/, Docker images, and CI. Use when adding Backend/UI/worker
  deploy to a repo or migrating from ad-hoc deploy/install scripts.
---

# Infra packager — onboard a product

## When to use

- New repo needs wget VPS install (backend + UI + workers + HTTPS gateway)
- Replacing hand-written install/start/update scripts with generated `dist/`

## Steps

1. **Depend on** [`vibed-infra`](https://www.npmjs.com/package/vibed-infra) or clone this repo for `package.sh`.

2. **Create** `templates/` with four files — see [`schema/packageconfig.md`](../../schema/packageconfig.md) and [`examples/vps-hello/templates/`](../../examples/vps-hello/templates/).

3. **Add** a tiny product `package.sh`:

```bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGER="$(node -e "console.log(require('path').dirname(require.resolve('vibed-infra/package.json')))")"
exec bash "$PACKAGER/package.sh" --product "$ROOT" --out "$ROOT/dist"
```

4. **Build images** — Dockerfiles in `app/`; tag `:local` for dev or push to GHCR for prod; reference image names in `*-config.yaml`.

5. **Package and commit** `dist/`:

```bash
./package.sh
git add dist && git commit && git push
```

6. **CI** — `npm test` (packager validate + install dry-run); optional `test-dist.sh --profile api|ui|nodes` after building images. See [`examples/vps-hello/test-dist.sh`](../../examples/vps-hello/test-dist.sh).

7. **VPS** — operators wget from your repo `dist/`:

```bash
wget -qO- .../dist/install-api.sh | bash
# edit .env, ./start-api.sh
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
wget -qO- .../dist/install-gateway.sh | bash
```

## Rules

- Infra never parses app config keys — only image names, ports, volume paths, site hostnames.
- Never overwrite existing `.env` on re-install.
- Gateway container names in `gateway.sites[]` must match running API/UI container names on `network.edge`.
- UI is a separate profile; gateway is nginx-only and does not start the UI.
