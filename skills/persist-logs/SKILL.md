---
name: persist-logs
description: >-
  Design recoverable apps on vibed-infra using append-only persist logs (local
  WAL + batched R2/S3 ship). Use when an app must rebuild state from events
  without relying on a database.
---

# Persist logs (event WAL)

## Goal

Each service writes **domain events** to a durable local log. After DB loss (or with no DB), **replay** rebuilds state. Shipping to R2/S3 is batched so small apps stay near $0.

## Paths

- Machine config (credentials + host cron leftover): `~/services/vibed-infra/persist-logs/` (one-time `install-persist-logs.sh`)
- Per deployment: Docker **named volume** `${DOCKER_NAME}-persist` mounted at `/persist-logs` (default). Set `PERSIST_LOGS=0` to disable. Bind escape: `PERSIST_LOG_BIND=1` + `PERSIST_LOG_DIR=…`.
- **Ship sidecar** `${DOCKER_NAME}-persist-ship` shares only that persist volume (no Docker socket, no app `/data`). Uses machine `.env` for R2/S3; app container does not get those secrets.
- Object keys: `{machine}/{PERSIST_SHIP_PREFIX}/{rel}` (prefix defaults to the app container name).

## Algorithm

1. **Append** NDJSON to `wal.ndjson` with fsync (fast, free).
2. **Seal** → `seg-NNNN.ndjson.gz` at ~8 MiB or ~60s.
3. **Ship** sealed segments with one PUT each (`PERSIST_SHIP=1` + R2/S3 env). Default `PERSIST_SHIP=0` (local only). Sidecar prefers stdlib SigV4; host cron may use `aws` CLI.
4. **Replay** sealed + wal in order.

Python: `lib/persistlog` — `append`, `seal`, `iter_events`, `replay`.

## Inspect on the VPS

```bash
~/services/vibed-infra/monitor-vibed.sh
# or:
docker run --rm -v "${DOCKER_NAME}-persist:/persist-logs:ro" alpine ls -laR /persist-logs
```

## Event schema

```json
{"ts":"2026-08-30T12:00:00Z","stream":"wallet","type":"tx.out","id":"...","payload":{...}}
```

### Log these

- State transitions: created, succeeded, failed
- Money/balance-affecting facts (wallet in/out)
- Job lifecycle, note creates (hello example)

### Do not log

- Secrets, raw passwords, full card data
- Huge blobs (store object key instead)
- Noisy HTTP access logs (use docker logs)

## Recovery

```python
from persistlog import replay

def apply(evt, bal):
    if evt["type"] == "tx.in":
        return bal + evt["payload"]["amount"]
    if evt["type"] == "tx.out":
        return bal - evt["payload"]["amount"]
    return bal

balance = replay("/persist-logs", "wallet", apply, 0)
```

## Cost

Prefer **Cloudflare R2** (free tier ~10 GB + 1M Class A ops/month, zero egress). Batch seals — never per-event PUT.
