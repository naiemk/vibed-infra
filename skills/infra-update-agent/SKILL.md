---
name: infra-update-agent
description: >-
  Machine-level serial Docker update queue for vibed-infra apps. Use when
  multiple products share one VPS and must not pull images in parallel; includes
  GHCR webhook enqueue via GitHub Actions OIDC (no extra GitHub secrets).
---

# Serial update agent

## Why

Five apps with auto-update cron would each `docker pull` at once and overload the box. The **update-agent** is installed once; apps only **enqueue** jobs.

## Layout

```
~/services/vibed-infra/update-agent/
  queue/ processing/ done/ failed/
  registry/{app}/{role}.json
  tokens/{app}     # optional local curl; CI uses OIDC instead
  agent.sh
  enqueue.sh
  webhook_server.py # 0.0.0.0:19200 (firewall: do not expose this port)
  lib/github_oidc.py
  .env              # WEBHOOK_PORT; optional WEBHOOK_SECRET
```

## Flow

1. Install registers the app (image + install dir).
2. Cron enqueues; agent cron (`*/5`) processes **serially**.
3. Image push: reusable GHCR workflow mints a GitHub Actions OIDC JWT (audience = webhook URL) and POSTs `{package,tag}` to `/_vibed/hooks/ghcr`.
4. Webhook verifies the JWT against GitHub’s JWKS (`iss`, `aud`, `exp`, RS256), then enqueues only registry images whose name contains `repository_owner`.
5. Agent runs `update-*.sh` immediately.

Gateway exposes `/_vibed/hooks/` on HTTP (port 80) and on each HTTPS site host.

## Zero extra GitHub setup

`gateway.publicIp` + `gateway.sites[].host` already in product config are the URLs. Auth is GitHub’s signature — no `VIBED_WEBHOOK_SECRET`.

Product workflow must grant OIDC to the reusable job:

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

Local curl can still use `X-Vibed-Secret` from `tokens/{app}` (compiled hash). Optional `WEBHOOK_SECRET` override remains.

## Register / enqueue manually

```bash
bash ~/services/vibed-infra/update-agent/enqueue.sh /path/to/api-install
```
