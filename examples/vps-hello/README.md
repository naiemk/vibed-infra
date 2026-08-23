# Example: VPS stack with vibed-infra

Minimal product source — **`package.sh`** writes committed **`dist/`** for wget VPS install.

## Source (you edit)

```
app/                          # Dockerfiles + app code
build-images.sh               # docker build :local tags
package.sh                    # proxy to vibed-infra packager
templates/
  api-config.yaml             # image, port, opaque config
  ui-config.yaml
  nodes-config.yaml
  vibed-infra-config.yml      # network, gateway sites, auto-update
```

## Maintainer flow

```bash
./build-images.sh             # optional locally
./package.sh                  # writes dist/
git add dist && git commit && git push
```

## Operator flow (VPS)

```bash
wget -qO- https://raw.githubusercontent.com/ORG/REPO/main/dist/install-api.sh | bash
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
wget -qO- .../dist/install-gateway.sh | bash
# edit each .env, then ./start-*.sh in each install dir
```

| Profile | Starts |
|---------|--------|
| `api` | Notes API on edge network |
| `ui` | Static UI container |
| `nodes` | Heartbeat worker → API |
| `gateway` | HTTPS nginx (UI + API must already run) |

Lab TLS: `./gen-dev-certs.sh` in the gateway install dir (copied from dist).

## Tests

```bash
./test-dist.sh --profile api
./test-dist.sh --profile ui
./test-dist.sh --profile nodes
```

CI runs the same three profiles in parallel after `npm test`.
