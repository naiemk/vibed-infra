# Playwright-friendly UI and CI setup

Design the product UI so Playwright tests are stable, fast, and maintainable.

## UI design rules

1. **`data-testid` on interactive elements** — prefer over CSS classes, auto-generated IDs, or visible text that changes with i18n.

```html
<form id="form" data-testid="note-form">
  <input data-testid="note-input" … />
  <button type="submit" data-testid="note-submit">Post</button>
</form>
<ul id="list" data-testid="note-list"></ul>
<p id="status" data-testid="status"></p>
```

2. **Stable routes** — use predictable URLs for auth and core flows (`/login`, `/dashboard`). Avoid hash-only navigation for critical paths.

3. **Reduce flakiness**
   - Set `aria-busy="true"` while loading; tests wait for `[aria-busy="false"]`.
   - Disable animations in e2e: `prefers-reduced-motion: reduce` via test env CSS, or `VIBED_E2E_HARNESS=1` body class.
   - Avoid `setTimeout`-driven UI; use explicit ready states.

4. **Auth state** — expose login via API or cookie the test can set; do not rely only on `localStorage` without a test hook.

5. **Error surfaces** — use `data-testid="error-message"` so failures are assertable without parsing console logs.

## Playwright config stub (`playwright.config.ts`)

```typescript
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "e2e/specs",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? [["github"], ["html"]] : "list",
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
```

Tag smoke tests: `test("user can post a note @smoke", …)`.

## Example spec stub

```typescript
import { test, expect } from "@playwright/test";

test("user can post a note @smoke", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByTestId("status")).toContainText("Live");
  await page.getByTestId("note-input").fill("hello e2e");
  await page.getByTestId("note-submit").click();
  await expect(page.getByTestId("note-list")).toContainText("hello e2e");
});
```

## E2e stack (`docker-compose.e2e.yml` stub)

```yaml
services:
  api:
    image: my-api:local
    build:
      context: app/api
      args:
        BUILD_PROFILE: e2e
    environment:
      VIBED_E2E_HARNESS: "1"
      E2E_CAPTCHA_SECRET: ci-test-secret
      DATABASE_URL: postgresql://e2e:e2e@postgres:5432/e2e
    ports:
      - "8080:8080"
    depends_on:
      postgres:
        condition: service_healthy

  ui:
    image: my-ui:local
    ports:
      - "3000:80"
    depends_on:
      - api

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: e2e
      POSTGRES_PASSWORD: e2e
      POSTGRES_DB: e2e
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "e2e"]
      interval: 5s
      retries: 5
```

Set `PLAYWRIGHT_BASE_URL=http://localhost:3000` in the Playwright job.

## CI job essentials

```yaml
- run: npx playwright install --with-deps chromium
- run: npx playwright test --grep @smoke
  env:
    PLAYWRIGHT_BASE_URL: http://localhost:3000
```

Upload `playwright-report/` as a CI artifact on failure.

## What not to do

- Do not use production GHCR `:main` images for e2e with harness enabled — build `:local` or use `BUILD_PROFILE=e2e`.
- Do not add test-only routes to production UI bundles without build-profile gating.
- Do not run Playwright against the VPS or production database.
