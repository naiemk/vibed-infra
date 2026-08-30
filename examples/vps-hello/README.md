# Example: VPS stack with vibed-infra

## Source

```
app/  build-images.sh  package.sh
templates/   # four YAML configs (network.edge: vps-edge)
dist/        # generated — includes DNS-SKILL.md
```

## Maintainer

```bash
./package.sh && git add dist && git commit && git push
# Paste dist/DNS-SKILL.md into AU agent; give it the VPS IP
```

## Operator

```bash
wget -qO- .../dist/install-api.sh | bash
wget -qO- .../dist/install-ui.sh | bash
wget -qO- .../dist/install-nodes.sh | bash
wget -qO- .../dist/install-gateway.sh | bash
# Host gateway: ~/services/gateway  +  apps/hello-vps/sites.conf
```

| Profile | Notes |
|---------|--------|
| `gateway` | Bootstraps shared host once; later apps only add `apps/{name}/` |
| `api` | Mounts `PERSIST_LOG_DIR` when set |

## Tests

```bash
./test-dist.sh --profile api|ui|nodes
# From repo root — dual-app host gateway via localhost wget:
npm run test:e2e-multi
```
