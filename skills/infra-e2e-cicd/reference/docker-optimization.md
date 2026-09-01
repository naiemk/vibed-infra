# Docker build optimization (pull size first, then build speed)

Every push to `main` triggers a digest-gated `docker pull` on the VPS. Optimize layers so **most pulls transfer minimal bytes**, then speed up CI builds.

## Priority rules

| Priority | Rule |
|----------|------|
| 1 | **Multi-stage**: slim runtime (`alpine`, `distroless`); compilers and devDeps stay in builder stage |
| 2 | **Layer order**: base → OS packages → lockfiles → install deps → **source last** |
| 3 | **`.dockerignore`**: exclude `node_modules`, `.git`, `e2e/`, `tests/`, `*.md`, `.env*` |
| 4 | **Pin base image** by digest in production Dockerfiles |
| 5 | **Avoid busting dep layers**: copy `package-lock.json` / `requirements.txt` before `COPY .` |
| 6 | **CI-only** (secondary): BuildKit cache mounts + GHA cache in reusable workflow |

GHA cache (`cache-from` / `cache-to: type=gha`) speeds CI rebuilds. It does **not** change what the VPS pulls — layer ordering and multi-stage builds do.

## `.dockerignore` (product root)

```
.git
node_modules
e2e
tests
**/*.md
.env*
dist
.github
```

## API — before (pull-unfriendly)

```dockerfile
FROM python:3.12-alpine
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
CMD ["python", "server.py"]
```

Every source change busts the dependency layer; full tree copied early.

## API — after (pull-friendly)

```dockerfile
FROM python:3.12-alpine@sha256:… AS runtime
RUN apk add --no-cache wget \
  && adduser -D -u 1000 app
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
ARG BUILD_PROFILE=production
ENV BUILD_PROFILE=$BUILD_PROFILE
RUN mkdir -p /data /config && chown -R app:app /data /config /app
USER 1000
EXPOSE 8080
CMD ["python3", "server.py"]
```

Lockfile copied first → dependency layer cached across commits. Only `server.py` (and siblings) bust on app changes.

## UI — static site with nginx (multi-stage)

```dockerfile
# builder — not shipped to VPS
FROM node:22-alpine@sha256:… AS builder
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG BUILD_PROFILE=production
ENV VITE_BUILD_PROFILE=$BUILD_PROFILE
RUN npm run build

# runtime — minimal pull
FROM nginx:1.27-alpine@sha256:…
COPY --from=builder /src/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

The VPS pulls only the nginx layer plus changed static assets — not Node, `node_modules`, or source.

## Worker / nodes

Same rules as API. Keep worker images separate from API so a UI change does not force an API pull (and vice versa).

## `BUILD_PROFILE` in Dockerfile

Products gate harness imports on build arg:

```dockerfile
ARG BUILD_PROFILE=production
ENV BUILD_PROFILE=$BUILD_PROFILE
```

- GHCR pushes (VPS): `BUILD_PROFILE=production` (reusable workflow default).
- Local e2e compose: `BUILD_PROFILE=e2e` only in `docker-compose.e2e.yml`.

Never set `BUILD_PROFILE=e2e` in VPS install `.env` or production GHCR workflow.

## Reusable workflow (CI build speed)

The vibed-infra reusable workflow passes:

```yaml
build-args: BUILD_PROFILE=production
cache-from: type=gha
cache-to: type=gha,mode=max
```

Products can override `build-args` per job if needed.

## Verify pull efficiency

On the VPS after a small code change:

```bash
docker pull ghcr.io/owner/my-api:main
# Should report "Already exists" for most layers; only changed layers download
```

Use `docker history ghcr.io/owner/my-api:main` to confirm large layers (deps, base) are stable across commits.
