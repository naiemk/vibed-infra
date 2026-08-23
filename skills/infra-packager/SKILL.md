---
name: infra-packager
description: >-
  Wire a new product to the infra VPS packager: packageconfig.yaml, Docker images,
  deploy/templates, thin install wrappers, and CI. Use when adding Backend/UI/worker
  deploy to a repo or migrating from ad-hoc deploy/install scripts.
---

# Infra packager — onboard a product

## When to use

- New repo needs wget VPS install (backend + UI + workers + HTTPS gateway)
- Splitting deploy scripts into reusable vibed-infra + product templates

## Steps

1. **Depend on** [`vibed-infra`](https://www.npmjs.com/package/vibed-infra) (`npm install vibed-infra`) or wget `install.sh` from this repo. Set `packagerRaw` in packageconfig.

2. **Create** `deploy/packageconfig.yaml` — see [`schema/packageconfig.md`](../../schema/packageconfig.md) and the VPS example [`examples/vps-hello/packageconfig.yaml`](../../examples/vps-hello/packageconfig.yaml).

3. **Add templates** under `deploy/templates/`:
   - `.env.*.example` (secrets — opaque to infra)
   - App config YAML (opaque)
   - `start-*.sh` / `update-*.sh` (or use generic `start.sh`)
   - Worker `docker-compose.*.yml` if multi-runner

4. **Thin wrappers** (set profile + product URLs):

```bash
# deploy/install/install-api.sh
export INFRA_PROFILE=api
export PACKAGECONFIG_URL=https://raw.githubusercontent.com/ORG/REPO/main/deploy/packageconfig.yaml
export PRODUCT_RAW=https://raw.githubusercontent.com/ORG/REPO/main/deploy/templates
wget -qO- https://raw.githubusercontent.com/naiemk/vibed-infra/main/install.sh | bash
```

5. **Build images** — Dockerfiles in `deploy/`; push to GHCR; reference in `packageconfig.images`.

6. **CI** — use [`github/workflows/docker-build-reusable.yml`](../../github/workflows/docker-build-reusable.yml); add install e2e serving the packager + `deploy/templates/` over HTTP.

7. **VPS** — per component directory:

```bash
mkdir -p ~/app/api && cd ~/app/api
wget -qO- .../deploy/install/install-api.sh | bash
# edit .env, then ./start-api.sh (or ./start.sh)
```

## Rules

- Infra never parses app config keys — only image names, ports, volume paths, site hostnames.
- Never overwrite existing `.env` on re-install.
- Gateway container names must match `sites[].backend` / `sites[].ui` on shared `network.edge`.
