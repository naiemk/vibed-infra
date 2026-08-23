# Product config schema (four files)

Product repos ship **templates only**. Run `package.sh` to generate committed `dist/` for VPS wget install.

## templates/vibed-infra-config.yml

```yaml
name: my-product
version: 1
templates:
  api: api-config.yaml
  ui: ui-config.yaml
  nodes: nodes-config.yaml
network:
  edge: my-product-edge
autoUpdate:
  api: { enabled: false, intervalMin: 30, offset: 0 }
  ui: { enabled: false, intervalMin: 20, offset: 15 }
  nodes: { enabled: false, intervalMin: 30, offset: 10 }
  gateway: { enabled: false, intervalMin: 20, offset: 20 }
gateway:
  nginxImage: nginx:alpine   # optional
  sites:
    - host: app.example.com
      aliases: [www.app.example.com]
      healthPath: /api/health
      createPath: /api/items   # optional rate-limited POST
      tlsCertDir: /etc/letsencrypt/live/app.example.com
```

Smart defaults: containers `{name}-api`, `{name}-ui`, `{name}-worker`, `{name}-gateway`.

## templates/api-config.yaml

```yaml
image: ghcr.io/org/my-api:main
port: 8080
config:          # opaque — written to dist/api-app.yaml
  title: My App
```

## templates/ui-config.yaml

```yaml
image: ghcr.io/org/my-ui:main
port: 80
```

## templates/nodes-config.yaml

```yaml
image: ghcr.io/org/my-worker:main
config:          # opaque — written to dist/nodes-workers.yaml
  intervalSec: 60
```

## dist/ (generated — commit and push)

| Path | Purpose |
|------|---------|
| `install-api.sh` / `install-ui.sh` / `install-nodes.sh` / `install-gateway.sh` | wget entrypoints |
| `packageconfig.yaml` | compiled for vibed-infra `install.sh` |
| `start-*.sh` / `update-*.sh` | generic lifecycle (from packager) |
| `gen-dev-certs.sh` | lab TLS helper |
| `.env.*.example` | generated env templates |

## Environment (install time)

| Variable | Meaning |
|----------|---------|
| `PACKAGER_RAW` | vibed-infra root (URL or path) |
| `PRODUCT_RAW` | dist/ URL or path |
| `PACKAGECONFIG_URL` | defaults to `dist/packageconfig.yaml` |
| `INFRA_PROFILE` | `api`, `ui`, `nodes`, or `gateway` |

Legacy `packageconfig.yaml`-only products still work; new products use the four-file layout + `package.sh`.
