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

- Machine root: `~/services/vibed-infra/persist-logs/` (one-time `install-persist-logs.sh`)
- Per app/role: `$PERSIST_LOG_DIR` (set in `.env`, mounted into API as `/persist-logs`)

## Algorithm

1. **Append** NDJSON to `wal.ndjson` with fsync (fast, free).
2. **Seal** → `seg-NNNN.ndjson.gz` at ~8 MiB or ~60s.
3. **Ship** sealed segments with one PUT each (`PERSIST_SHIP=1` + R2/S3 env). Default `PERSIST_SHIP=0` (local only).
4. **Replay** sealed + wal in order.

Python: `lib/persistlog` — `append`, `seal`, `iter_events`, `replay`.

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
