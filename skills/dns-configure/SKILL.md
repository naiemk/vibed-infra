---
name: dns-configure
description: >-
  Point product domains at a VPS using the generated dist/DNS-SKILL.md pasted
  into an AU agent browser extension. Prefer the baked gateway.publicIp when
  present; otherwise ask the user for the VPS IP.
---

# DNS via AU agent browser extension

1. Product maintainer sets `gateway.publicIp` (+ `gateway.sites[].host`) in `vibed-infra-config.yml`, runs `./package.sh` → committed **`dist/DNS-SKILL.md`**.
2. Operator copies the entire file into an **AU agent browser extension**.
3. Agent creates **A** records for each hostname in the skill table:
   - If the table already shows an IPv4, **confirm** it with the operator (from `gateway.publicIp`).
   - If the value is `{{VPS_IP}}`, ask the operator for the VPS public IPv4.
4. After dig confirms resolution, on the VPS run `~/services/gateway/setup-tls.sh` (or `install-gateway.sh`), then start the host gateway if needed.

The skill is self-contained (no vibed-infra checkout). Re-package after changing `gateway.sites[]` or `gateway.publicIp`.
