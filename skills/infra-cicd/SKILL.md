---
name: infra-cicd
description: >-
  Set up GitHub Actions CI/CD for infra-packaged products: GHCR image build,
  package validation, and dist e2e (api/ui/nodes). Use when adding deploy
  pipelines for Backend/UI/worker images.
---

# Infra packager CI/CD

## Image build (GHCR)

Use reusable workflow [`github/workflows/docker-build-reusable.yml`](../../github/workflows/docker-build-reusable.yml):

```yaml
jobs:
  images:
    uses: naiemk/vibed-infra/.github/workflows/docker-build-reusable.yml@main
    with:
      dockerfile: app/api/Dockerfile
      image: ghcr.io/${{ github.repository_owner }}/my-api
    secrets: inherit
```

Tags: `:main`, `main-<sha>`, semver on tag push.

## CI in vibed-infra

1. **`npm test`** — runs `package.sh` for `examples/vps-hello`, dry-runs each `dist/install-*.sh` (no Docker).
2. **`dist-e2e` matrix** — `api`, `ui`, `nodes` via `examples/vps-hello/test-dist.sh` (builds images + proves each profile).

## Product repo CI

1. Run `./package.sh` and fail if `dist/` drifted from templates (optional `git diff --exit-code dist`).
2. Build/push images to GHCR; bump image tags in `*-config.yaml`; re-package.
3. Optional job: `test-dist.sh --profile api` on a Docker-enabled runner.

## Checklist

- [ ] Four YAML templates under `templates/`
- [ ] Committed `dist/` matches `./package.sh` output
- [ ] Image names in configs match GHCR
- [ ] `npm test` / install dry-run passes
- [ ] Secrets not in templates — only `.env.*.example` placeholders
