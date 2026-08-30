---
name: infra-cicd
description: >-
  Set up GitHub Actions CI/CD for infra-packaged products: GHCR image build,
  OIDC notify for immediate VPS pulls, package validation, and dist e2e.
---

# Infra packager CI/CD

## Image build (GHCR)

Use reusable workflow [`github/workflows/docker-build-reusable.yml`](../../github/workflows/docker-build-reusable.yml):

```yaml
jobs:
  images:
    uses: naiemk/vibed-infra/.github/workflows/docker-build-reusable.yml@main
    permissions:
      contents: read
      packages: write
      id-token: write
    with:
      dockerfile: app/api/Dockerfile
      image: ghcr.io/${{ github.repository_owner }}/my-api
```

Tags: `:main`, `main-<sha>`, semver on tag push.

On the default branch, the reusable workflow mints a GitHub Actions OIDC JWT (audience = webhook URL) and POSTs to `https://{host}/_vibed/hooks/ghcr` (fallback `http://{publicIp}/…`). No GitHub Packages webhook and no extra secrets. Disable with `notify: false`. The caller job **must** include `id-token: write`.

## CI in vibed-infra

1. **`npm test`** — runs `package.sh` for `examples/vps-hello`, dry-runs each `dist/install-*.sh` with `TLS_MODE=lab` (no Docker / no certbot). Includes local openssl JWT verify of the webhook.
2. **`oidc-webhook-e2e`** — `scripts/e2e-oidc-webhook.sh` mints a **real** GitHub OIDC token in CI and POSTs a local webhook (`REQUIRE_OIDC_E2E=1`).
3. **`dist-e2e` matrix** — `api`, `ui`, `nodes` via `examples/vps-hello/test-dist.sh` (builds images + proves each profile).
4. **`multi-app-e2e`** — `scripts/e2e-multi-app.sh` / `npm run test:e2e-multi` (two apps, localhost wget, shared host gateway + lab TLS).

## Product repo CI

1. Run `./package.sh` and fail if `dist/` drifted from templates (optional `git diff --exit-code dist`).
2. Build/push images to GHCR (reusable workflow notifies the VPS; requires `id-token: write`).
3. Optional job: `test-dist.sh --profile api` on a Docker-enabled runner.

## Checklist

- [ ] Four YAML templates under `templates/` (`gateway.publicIp` / `tlsEmail` / `sites[]` set for production)
- [ ] Committed `dist/` matches `./package.sh` output (including `DNS-SKILL.md`)
- [ ] Image names in configs match GHCR (`ghcr.io/{owner}/…` so OIDC `repository_owner` can match)
- [ ] GHCR reusable job has `permissions.id-token: write`
- [ ] `npm test` / install dry-run passes
- [ ] Secrets not in templates — only `.env.*.example` placeholders (publicIp/domain are OK to commit)
