# vibed-infra

Product-agnostic VPS deployment packager: **`package.sh`** turns four YAML configs into a committed **`dist/`** tree operators wget on the box — install scripts, generic start/update helpers, env examples, and gateway nginx.

Published on npm as **`vibed-infra`**.

## Product maintainer flow

Author **`templates/`** in your product repo:

| File | Purpose |
|------|---------|
| `vibed-infra-config.yml` | Product name, template refs, edge network, gateway `sites[]`, auto-update |
| `api-config.yaml` | API image, port, opaque `config:` |
| `ui-config.yaml` | UI image, port |
| `nodes-config.yaml` | Worker image, opaque `config:` |

Then package and commit **`dist/`**:

```bash
./package.sh                  # exec vibed-infra packager → writes dist/
git add dist && git commit && git push
```

Resolve the packager from npm:

```bash
node -e "console.log(require('path').dirname(require.resolve('vibed-infra/package.json')))"
```

Example product: [`examples/vps-hello`](examples/vps-hello) (`app/`, `build-images.sh`, four YAMLs, committed `dist/`).

## Operator flow (wget on VPS)

```bash
wget -qO- https://raw.githubusercontent.com/ORG/REPO/main/dist/install-api.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-gateway.sh | bash
# edit each install dir .env, then ./start-*.sh
```

| Profile | Role |
|---------|------|
| `api` | Backend on shared edge network |
| `ui` | UI container (separate install) |
| `nodes` | Worker compose on edge network |
| `gateway` | HTTPS nginx only (API + UI must already run) |

## Layout

| Path | Purpose |
|------|---------|
| `package.sh` / `lib/package.py` | Build product `dist/` from four YAMLs + generic templates |
| `install.sh` | Single entrypoint (`INFRA_PROFILE` or `--profile`) |
| `install-auto-update.sh` | Cron from profile flags |
| `lib/` | fetch, env, tls, prompt, generate, product_config |
| `templates/generic/` | Generic start/update/env/certs/gateway |
| `schema/packageconfig.md` | Four-file product schema + compiled packageconfig |
| `examples/vps-hello/` | Full example with dist e2e tests |
| `skills/` | Cursor skills |
| `github/workflows/` | Reusable GHCR build workflow |

## Environment

| Variable | Meaning |
|----------|---------|
| `PACKAGER_RAW` | Base URL or local path to this package root |
| `PACKAGECONFIG_URL` | Product `packageconfig.yaml` or `dist/` URL (URL or path) |
| `PRODUCT_RAW` | Product `dist/` base (templates + install scripts) |
| `INFRA_PROFILE` | `api`, `ui`, `nodes`, or `gateway` |
| `INSTALL_DIR` | Target directory (default `.`) |

## Tests

```bash
npm test                        # package + dry-run all dist/install-*.sh
npm run test:dist               # build images + e2e api, ui, nodes (sequential)
./examples/vps-hello/test-dist.sh --profile api   # single profile
```

CI: `validate` job then parallel `dist-e2e` matrix (`api`, `ui`, `nodes`).

## Publishing (npm)

Every **merge to `main`** runs [Publish npm](.github/workflows/publish.yml):

1. Bumps **minor** (`0.1.0` → `0.2.0`)
2. Commits `chore: release vibed-infra v…`, tags `v…`, pushes
3. Runs `npm publish` (needs repo secret `NPM_TOKEN`)

**Major versions** — set `version` in `package.json` yourself (e.g. `1.0.0`) and include **`[major]`** in the commit message. That publishes the pinned version with **no** automatic minor bump.

Set repository secret **`NPM_TOKEN`** before the first merge to `main`.

Ordinary PRs only run CI (`npm test` + dist e2e); they do **not** publish.

Runbook: [`examples/vps-hello/README.md`](examples/vps-hello/README.md).
