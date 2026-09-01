# CI human-action harnesses (passkeys, wallet, captcha)

Simulate human interactions in Playwright CI only. **Harness code must be completely unavailable on VPS production builds.**

## Three-layer VPS exclusion contract

1. **Source layout** — all harness code under `e2e/` or `test/harness/`; never in `app/` production paths imported by the server entrypoint.
2. **Build gate** — `BUILD_PROFILE=production` excludes harness modules; GHCR images use production profile only (reusable workflow default).
3. **Runtime gate** — `VIBED_E2E_HARNESS` unset on VPS; CI compose sets `VIBED_E2E_HARNESS=1`.

## Verification (product CI)

After building a production-profile image, assert harness routes are absent:

```bash
cid=$(docker run -d -p 18080:8080 prod-api:ci)
trap "docker rm -f $cid" EXIT
sleep 2
code=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:18080/__e2e__/health || echo "000")
test "$code" = "404" || test "$code" = "000" || (echo "harness leaked: HTTP $code" && exit 1)
```

Never add `VIBED_E2E_HARNESS`, `E2E_CAPTCHA_SECRET`, or harness URLs to VPS `.env` templates or committed `dist/`.

---

## Passkeys / WebAuthn

**CI approach:** Playwright CDP virtual authenticator; optional test-only registration endpoint when harness is on.

**VPS exclusion:** Route module in `e2e/harness/webauthn_routes.py` (or equivalent); imported only when `BUILD_PROFILE=e2e` or dynamic import gated on `VIBED_E2E_HARNESS`.

### Playwright virtual authenticator stub (`e2e/harness/webauthn.ts`)

```typescript
import { type BrowserContext, type CDPSession } from "@playwright/test";

export async function enableVirtualAuthenticator(context: BrowserContext) {
  const page = context.pages()[0] ?? await context.newPage();
  const client = await context.newCDPSession(page);
  await client.send("WebAuthn.enable");
  const { authenticatorId } = await client.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
    },
  });
  return { client, authenticatorId };
}
```

### Test-only server route stub (`e2e/harness/webauthn_routes.py`)

```python
# Import ONLY from e2e entrypoint when VIBED_E2E_HARNESS=1 — never from prod server.py
import os
from flask import Blueprint, jsonify

bp = Blueprint("e2e_webauthn", __name__, url_prefix="/__e2e__/webauthn")

@bp.route("/register", methods=["POST"])
def register_credential():
    if os.environ.get("VIBED_E2E_HARNESS") != "1":
        return jsonify(error="not found"), 404
    # Return a fixed test credential payload for the app's WebAuthn verify step
    return jsonify({"credentialId": "e2e-test-credential", "publicKey": "…"})
```

Wire `bp` in an `e2e/server_extensions.py` that production `server.py` never imports.

---

## MetaMask / wallet signing

**CI approach:** Inject `window.ethereum` mock via Playwright `addInitScript`; optionally use [Synpress](https://github.com/Synthetixio/synpress) for extension-based flows in CI only.

**VPS exclusion:** Mock script lives in `e2e/harness/`; never bundled in production UI build.

### Wallet mock stub (`e2e/harness/ethereum-mock.ts`)

```typescript
import { type Page } from "@playwright/test";

const TEST_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

export async function injectEthereumMock(page: Page) {
  await page.addInitScript(({ address }) => {
    (window as unknown as { ethereum?: unknown }).ethereum = {
      isMetaMask: true,
      selectedAddress: address,
      request: async ({ method }: { method: string }) => {
        if (method === "eth_requestAccounts") return [address];
        if (method === "eth_accounts") return [address];
        if (method === "personal_sign") return "0x" + "ab".repeat(32);
        if (method === "eth_chainId") return "0x1";
        throw new Error(`unsupported: ${method}`);
      },
    };
  }, { address: TEST_ADDRESS });
}
```

### Example spec usage

```typescript
test("wallet connect and sign @smoke", async ({ page }) => {
  await injectEthereumMock(page);
  await page.goto("/connect");
  await page.getByTestId("connect-wallet").click();
  await expect(page.getByTestId("wallet-address")).toContainText("0x7099");
});
```

Do not ship MetaMask extension or mock provider in production Docker images.

---

## Captcha

**CI approach:** Server accepts `X-E2E-Captcha-Bypass: $E2E_CAPTCHA_SECRET` when harness env is set; Playwright sets header globally or per request.

**VPS exclusion:** Bypass handler in separate module; eliminated from production build via `BUILD_PROFILE=production`.

### Server bypass stub (`e2e/harness/captcha_bypass.py`)

```python
import os

def captcha_verified(request) -> bool:
    if os.environ.get("VIBED_E2E_HARNESS") != "1":
        return False  # production path uses real captcha provider only
    secret = os.environ.get("E2E_CAPTCHA_SECRET", "")
    return secret and request.headers.get("X-E2E-Captcha-Bypass") == secret
```

Use in your captcha middleware:

```python
if captcha_verified(request):
    return  # skip provider verify in CI only
# … real hCaptcha / Turnstile verify …
```

### Playwright global header (`playwright.config.ts`)

```typescript
use: {
  extraHTTPHeaders: process.env.VIBED_E2E_HARNESS === "1"
    ? { "X-E2E-Captcha-Bypass": process.env.E2E_CAPTCHA_SECRET ?? "" }
    : {},
},
```

Set `E2E_CAPTCHA_SECRET` only in CI secrets or e2e compose — never on VPS.

---

## Harness health endpoint (CI only)

Optional liveness for e2e compose debugging:

```python
@bp.route("/health")
def harness_health():
    if os.environ.get("VIBED_E2E_HARNESS") != "1":
        return "", 404
    return jsonify(ok=True)
```

Production profile must return **404** for `/__e2e__/health` — verified in the `harness-absence` CI job.

## Summary

| Harness | CI simulator | VPS must not have |
|---------|--------------|-------------------|
| Passkeys | CDP virtual authenticator + optional `/__e2e__/webauthn/*` | Virtual auth routes, test credentials |
| Wallet | `window.ethereum` mock in Playwright | Extension, mock provider in bundle |
| Captcha | `X-E2E-Captcha-Bypass` header + env secret | Bypass env vars, bypass middleware in prod build |

Products wire app-specific flows on top of these stubs; vibed-infra documents the pattern, not a shared npm package.
