---
name: infra-cicd
description: >-
  Set up GitHub Actions CI/CD for infra-packaged products: GHCR image build,
  compose smoke, and install e2e against published images. Use when adding deploy
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
      dockerfile: deploy/Dockerfile.api
      image: ghcr.io/${{ github.repository_owner }}/my-api
    secrets: inherit
```

Or copy the workflow into the product repo. Tags: `:main`, `main-<sha>`, semver on tag push.

## Install e2e (optional job)

1. Serve repo over HTTP (Python `http.server` at repo root or multi-path).
2. Set `PACKAGER_RAW` to the packager (npm path, git checkout, or HTTP) and `PACKAGECONFIG_URL=.../deploy/packageconfig.yaml`.
3. Optionally set `PRODUCT_RAW` if it should differ from `packageconfig.rawBase`.
4. Run the product `install-api.sh` into a temp dir.
5. Fill `.env` with test secrets; `./start-*.sh`; curl health.

See [`examples/vps-hello/scripts/try-install.sh`](../../examples/vps-hello/scripts/try-install.sh) for a packager-only dry-run.

## packageconfig in CI

- `IMAGE_TAG=main` in system tests matches GHCR `:main` from default branch push.
- Keep `rawBase` pointing at `main` branch raw URLs for operator wget; override with `PRODUCT_RAW` on a feature branch.

## Checklist

- [ ] Dockerfiles under `deploy/`
- [ ] `deploy/packageconfig.yaml` images match GHCR names
- [ ] Install dry-run or workflow job passes
- [ ] Secrets not in templates — only `.env.example` placeholders
