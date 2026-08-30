---
name: infra-update-agent
description: >-
  Machine-level serial Docker update queue for vibed-infra apps. Use when
  multiple products share one VPS and must not pull images in parallel; includes
  GHCR webhook enqueue.
---

# Serial update agent

## Why

Five apps with auto-update cron would each `docker pull` at once and overload the box. The **update-agent** is installed once; apps only **enqueue** jobs.

## Layout

```
~/services/vibed-infra/update-agent/
  queue/ processing/ done/ failed/
  registry/{app}/{role}.json
  agent.sh          # claims one job, runs that install’s update-*.sh, prune
  enqueue.sh
  webhook_server.py # 127.0.0.1:19200
  .env              # WEBHOOK_SECRET, WEBHOOK_PORT
```

## Flow

1. First install runs `templates/update-agent/install-agent.sh`.
2. Per-app cron (via `install-auto-update.sh`) calls `enqueue.sh` instead of `update-*.sh`.
3. Agent cron (`*/5`) processes the queue **serially**.
4. Optional: GHCR/GitHub package webhook → `POST` with `X-Vibed-Secret` and `{package,tag}` → enqueue matching registry entries → agent.

Gateway exposes `/_vibed/hooks/ghcr` to the webhook port.

## Register / enqueue manually

```bash
bash ~/services/vibed-infra/update-agent/enqueue.sh /path/to/api-install
```
