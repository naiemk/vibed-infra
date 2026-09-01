---
name: infra-e2e-cicd
description: >-
  E2E CI/CD for vibed-infra products: GHCR build/tag (UI/API/nodes), OIDC
  auto-update, Docker pull-size optimization, Playwright critical paths, temp DB,
  CI-only human-action harnesses. Use when setting up product GitHub Actions
  or browser e2e tests.
---

# E2E CI/CD for vibed-infra products

Best practices for product repos that use the infra packager. An agent should read this skill after [`infra-packager`](../infra-packager/SKILL.md) and apply the reference templates to the product repo.

## Separation of concerns

| Layer | What it proves | Where |
|-------|----------------|-------|
| **vibed-infra CI** | Install scripts, named volumes, OIDC webhook, multi-app gateway | This repo — `npm test`, `test:dist`, `test:e2e-multi` |
| **Product CI** | App critical paths, Playwright UI flows, temp DB, human-action harnesses | Product repo — see [reference/product-ci-workflow.yml](reference/product-ci-workflow.yml) |

vibed-infra CI does **not** run Playwright. Products add browser e2e for their own critical paths.

## Product CI job graph

```
validate (package drift + unit tests)
  → build-api / build-ui / build-nodes (GHCR push + OIDC notify)
  → e2e-playwright (temp DB, VIBED_E2E_HARNESS=1)
  → harness-absence check (production-profile image returns 404 on /__e2e__/*)
```

On default-branch push, each GHCR build job notifies the VPS via OIDC (see [`infra-update-agent`](../infra-update-agent/SKILL.md)). Tags: `:main`, `main-<sha>`, semver on release tag.

## Critical paths

1. **Identify** user journeys that must never break: sign-in, core CRUD, checkout, wallet sign, etc.
2. **One Playwright spec per journey** — keep specs focused; use smoke vs full suite tags (`@smoke`).
3. **Map selectors** to stable `data-testid` attributes (see [reference/playwright-ui.md](reference/playwright-ui.md)).
4. **Never point e2e at prod or VPS DB** — always use a temp database per CI job.

## Temp DB

- **Postgres**: GitHub Actions `services:` block or `docker compose` service; unique database name per job (`e2e_${{ github.run_id }}`).
- **SQLite**: tmpfile path in env; delete on job end.
- Run migrations **before** Playwright starts (`npx prisma migrate`, `alembic upgrade`, etc.).
- Seed minimal fixtures in the e2e setup hook, not in production migrations.

## VPS vs CI images

| | VPS (production) | CI (e2e) |
|---|------------------|----------|
| Tag | `:main` from GHCR | `:local` or `:main-<sha>` built in job |
| `BUILD_PROFILE` | `production` (default in reusable workflow) | `e2e` only in e2e compose |
| `VIBED_E2E_HARNESS` | unset | `1` |
| Harness routes | **404 / absent** | available for simulators |

Production images pushed to GHCR use `BUILD_PROFILE=production` by default (reusable workflow). Harness code lives under `e2e/` and is never imported by the production server entrypoint.

## Reference docs

| Topic | File |
|-------|------|
| Full product CI workflow | [reference/product-ci-workflow.yml](reference/product-ci-workflow.yml) |
| Docker pull-size optimization | [reference/docker-optimization.md](reference/docker-optimization.md) |
| Playwright-friendly UI + config | [reference/playwright-ui.md](reference/playwright-ui.md) |
| Passkey / wallet / captcha harnesses | [reference/human-harnesses.md](reference/human-harnesses.md) |

## GHCR build (one job per image)

Use the reusable workflow from vibed-infra (see [`infra-cicd`](../infra-cicd/SKILL.md)):

```yaml
build-api:
  uses: naiemk/vibed-infra/.github/workflows/docker-build-reusable.yml@main
  permissions:
    contents: read
    packages: write
    id-token: write
  with:
    dockerfile: app/api/Dockerfile
    image: ghcr.io/${{ github.repository_owner }}/my-api
    build-args: BUILD_PROFILE=production
```

Repeat for UI and nodes/worker images. Image names must match `*-config.yaml` and include `ghcr.io/{owner}/…` so OIDC notify matches the update-agent registry.

## Checklist

- [ ] Critical paths listed and covered by Playwright specs
- [ ] `./package.sh` + `git diff --exit-code dist` in CI validate job
- [ ] GHCR jobs for api, ui, nodes with `id-token: write`
- [ ] Dockerfiles follow [docker-optimization.md](reference/docker-optimization.md) (pull size first)
- [ ] UI uses `data-testid` on interactive elements
- [ ] E2e uses temp DB; migrations run before tests
- [ ] Harness code only under `e2e/`; production build excludes it
- [ ] CI asserts `/__e2e__/health` returns 404 on production-profile image
- [ ] `VIBED_E2E_HARNESS` never set in VPS `.env` or `dist/` templates

## Agent workflow

1. Read `infra-packager` → wire templates + commit `dist/`.
2. Apply [product-ci-workflow.yml](reference/product-ci-workflow.yml) to `.github/workflows/ci.yml`.
3. Optimize Dockerfiles per [docker-optimization.md](reference/docker-optimization.md).
4. Add Playwright config + specs per [playwright-ui.md](reference/playwright-ui.md).
5. Add harness stubs from [human-harnesses.md](reference/human-harnesses.md) under `e2e/` only.
6. Add prod-image harness-absence check to CI.
7. Wire GHCR matrix with `id-token: write` per `infra-update-agent`.
