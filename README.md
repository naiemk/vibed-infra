# vibed-infra

Product-agnostic VPS deployment packager: wget installer, Docker Compose layouts, digest-gated auto-update, TLS/nginx helpers, and CI workflow templates.

Published on npm as **`vibed-infra`**.

## Install (npm)

```bash
npm install vibed-infra
# or in a monorepo sibling checkout:
# "vibed-infra": "file:../vibed-infra"
```

Resolve the packager root from Node:

```bash
node -e "console.log(require('path').dirname(require.resolve('vibed-infra/package.json')))"
```

Run install locally (product `packageconfig.yaml` + templates required):

```bash
PACKAGER_RAW=/path/to/node_modules/vibed-infra \
PACKAGECONFIG_URL=/path/to/product/deploy/packageconfig.yaml \
ONCHAIN_INVOICE_RAW=/path/to/product/deploy/templates \
bash /path/to/node_modules/vibed-infra/install.sh --profile api
```

Or use the bin:

```bash
npx vibed-infra --profile api   # still needs PACKAGECONFIG_URL / product templates env
```

## Install (wget, operators)

```bash
wget -qO- https://raw.githubusercontent.com/naiemk/vibed-infra/main/install.sh | \
  env INFRA_PROFILE=api \
      PACKAGECONFIG_URL=https://raw.githubusercontent.com/naiemk/onchain-invoice/main/deploy/packageconfig.yaml \
      ONCHAIN_INVOICE_RAW=https://raw.githubusercontent.com/naiemk/onchain-invoice/main/deploy/templates \
      bash
```

## Layout

| Path | Purpose |
|------|---------|
| `install.sh` | Single entrypoint (`INFRA_PROFILE` or `--profile`) |
| `start.sh` / `update.sh` | Generic lifecycle in install dir |
| `install-auto-update.sh` | Cron from profile flags |
| `lib/` | fetch, env, tls, prompt, generate |
| `templates/` | Generic compose/nginx skeletons |
| `schema/packageconfig.md` | Schema reference |
| `skills/` | Cursor skills |
| `github/workflows/` | Reusable GHCR build workflow |

## Environment

| Variable | Meaning |
|----------|---------|
| `PACKAGER_RAW` | Base URL or local path to this package root |
| `PACKAGECONFIG_URL` | Product `packageconfig.yaml` (URL or path) |
| `INFRA_PROFILE` | `api`, `nodes`, or `gateway` |
| `INSTALL_DIR` | Target directory (default `.`) |
| `ONCHAIN_INVOICE_RAW` | Product templates base (opaque to infra) |

## Trustless Commerce

First consumer: [onchain-invoice](https://github.com/naiemk/onchain-invoice) — `deploy/packageconfig.yaml` + `deploy/templates/`.
