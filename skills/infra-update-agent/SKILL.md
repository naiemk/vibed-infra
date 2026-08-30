---
name: infra-update-agent
description: >-
  Machine-level serial Docker update queue for vibed-infra apps. Use when
  multiple products share one VPS and must not pull images in parallel; includes
  immediate GHCR pulls via GitHub Actions OIDC (no extra GitHub secrets).
---

# Serial update agent

## Why

Five apps with auto-update cron would each `docker pull` at once and overload the box. The **update-agent** is installed once; apps only **enqueue** jobs. The agent runs `update-*.sh`, which is **digest-gated**: pull if the registry digest changed, restart only if the running container is stale.

## Layout

```
~/services/vibed-infra/update-agent/
  queue/ processing/ done/ failed/
  registry/{app}/{role}.json   # image + installDir (written at wget install)
  tokens/{app}                # optional local curl; CI uses OIDC
  agent.sh
  enqueue.sh
  webhook_server.py            # 0.0.0.0:19200 — do not open this port publicly
  lib/github_oidc.py
  .env                         # WEBHOOK_PORT=19200
```

Override the directory with `VIBED_UPDATE_AGENT` (wins over `VIBED_HOME`).

## Pull paths

```
git push main
  → reusable GHCR workflow builds/pushes :main
  → notify-vps-pull.py mints OIDC JWT (aud = webhook URL)
  → POST https://{host}/_vibed/hooks/ghcr   (fallback http://{publicIp}/…)
  → nginx → webhook_server (verify GitHub JWKS)
  → enqueue matching registry entries (owner must appear in image name)
  → agent.sh → update-{role}.sh → docker pull + restart if digest changed
```

- **Immediate:** default-branch image push. Caller job needs `id-token: write`. No GitHub Packages webhook and no `VIBED_WEBHOOK_SECRET`.
- **Cron backup:** `*_AUTO_UPDATE=1` enqueues on an interval; agent cron `*/5` drains the queue if notify was missed.
- **Manual:** `bash ~/services/vibed-infra/update-agent/enqueue.sh /path/to/api-install`

Gateway HTTP (`00-default.conf`) and each HTTPS site proxy `/_vibed/hooks/` to `host.docker.internal:19200`. Keep **19200** off the public firewall; only 80/443.

## Product CI

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

URLs come from `gateway.publicIp` + `gateway.sites[].host` already in config (`dist/packageconfig.yaml` `webhook.url` / `fallbackUrl`). Disable notify with `notify: false`.

Local curl can send `X-Vibed-Secret` from `tokens/{app}` (compiled hash). Optional `WEBHOOK_SECRET` still works as an override.

## Tests

- `npm test` — openssl-signed JWT (same verifier) + enqueue under `VIBED_UPDATE_AGENT`
- `npm run test:oidc` / CI job `oidc-webhook-e2e` — real GitHub OIDC mint against a local webhook
