---
name: dns-configure
description: >-
  Point product domains at a VPS using the generated dist/DNS-SKILL.md pasted
  into an AU agent browser extension. User must provide the VPS IP.
---

# DNS via AU agent browser extension

1. Product maintainer runs `./package.sh` → committed **`dist/DNS-SKILL.md`**.
2. Operator copies the entire file into an **AU agent browser extension**.
3. Operator tells the agent the **VPS public IPv4** (required — agents must not invent IPs).
4. Agent creates **A** records for each `gateway.sites[]` host and alias → that IP.
5. After dig confirms resolution, run certbot / start host gateway TLS on the VPS.

The skill is self-contained (no vibed-infra checkout). Re-package after changing `gateway.sites[]`.
