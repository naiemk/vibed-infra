# Example: VPS stack with vibed-infra

A complete product that **uses** [`vibed-infra`](../..) to install API + worker + HTTPS gateway on a VPS. The app itself is a tiny notes board so the packager contract is the point, not the product.

| Profile | Role | What it starts |
|---------|------|----------------|
| `api` | backend | Notes API (`hello-api:8080`) on `hello-vps-edge` |
| `nodes` | workers | Heartbeat worker that POSTs `/api/notes` |
| `gateway` | gateway | Static UI + nginx on 80/443 |

Same layout a real product keeps under `deploy/`: `packageconfig.yaml`, `templates/`, thin `install/*.sh` wrappers.

## VPS runbook

One Ubuntu/Debian box with Docker. DNS A records for `hello.example.com` and `www.hello.example.com` (or edit `packageconfig.yaml` `sites[]` / the generated `gateway/conf.d/domains.conf` after install).

### 1. Prereqs

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 certbot python3 openssl
sudo systemctl enable --now docker
sudo systemctl disable --now nginx || true   # free :80 / :443
```

### 2. Build images on the box

Images default to `:local` so you do not need GHCR for this example.

```bash
git clone https://github.com/naiemk/vibed-infra.git
cd vibed-infra
./examples/vps-hello/scripts/build-images.sh
```

Point `images:` in `packageconfig.yaml` at GHCR (and set `*_AUTO_UPDATE=1`) when you publish.

### 3. Install each profile into its own directory

```bash
mkdir -p ~/hello-vps/{api,nodes,gateway}

cd ~/hello-vps/api
bash /path/to/vibed-infra/examples/vps-hello/install/install-api.sh

cd ~/hello-vps/nodes
bash /path/to/vibed-infra/examples/vps-hello/install/install-nodes.sh

cd ~/hello-vps/gateway
bash /path/to/vibed-infra/examples/vps-hello/install/install-gateway.sh
```

Or wget after this tree is on `main`:

```bash
cd ~/hello-vps/api
wget -qO- https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/install/install-api.sh | bash
```

Edit each `.env`: set a real `API_TOKEN` (same value on API + workers). Change `sites[].host` / TLS paths if your domain is not `hello.example.com`.

### 4. TLS

Production (port 80 free, DNS live):

```bash
sudo mkdir -p /var/www/certbot
sudo certbot certonly --standalone \
  -d hello.example.com -d www.hello.example.com
```

Set `TLS_FULLCHAIN` / `TLS_PRIVKEY` in `~/hello-vps/gateway/.env` to the Let's Encrypt files.

Lab box without public DNS:

```bash
./examples/vps-hello/scripts/gen-dev-certs.sh ~/hello-vps/gateway/certs
# then point TLS_* in gateway .env at those pems
```

### 5. Start (API first — it owns the edge network)

```bash
cd ~/hello-vps/api && ./start-hello-api.sh
cd ~/hello-vps/nodes && ./start-hello-nodes.sh
cd ~/hello-vps/gateway && ./start-hello-gateway.sh
```

```bash
curl -s http://127.0.0.1:8080/api/health
curl -fk https://127.0.0.1/api/health -H 'Host: hello.example.com'
```

Open `https://hello.example.com`. To post from the UI when `API_TOKEN` is set, add `?token=…` to the URL.

## What install copies

`vibed-infra/install.sh` reads this example's `packageconfig.yaml` and writes into `INSTALL_DIR`:

- `.env` from the profile `.env.*.example` (never overwritten if it already exists)
- App YAML + start/update scripts from `templates/`
- Generic compose skeletons from the packager
- Generated `gateway/conf.d/domains.conf` from `sites[]`

Then `./install-auto-update.sh` installs cron when the profile `*_AUTO_UPDATE` flag is on.

## Local checkout (no wget)

From this repo:

```bash
./examples/vps-hello/scripts/try-install.sh
```

That runs the real packager into a temp dir and checks the three profiles landed. Docker is not required.

To bring the stack up on the same machine you cloned on:

```bash
./examples/vps-hello/scripts/build-images.sh
HELLO_TRY_KEEP=1 HELLO_TRY_DIR=/tmp/hello-vps ./examples/vps-hello/scripts/try-install.sh
./examples/vps-hello/scripts/gen-dev-certs.sh /tmp/hello-vps/gateway/certs
# set TLS_* in /tmp/hello-vps/gateway/.env to those certs, then:
/tmp/hello-vps/api/start-hello-api.sh
/tmp/hello-vps/nodes/start-hello-nodes.sh
/tmp/hello-vps/gateway/start-hello-gateway.sh
```

## Copy this into your product

1. Copy `packageconfig.yaml`, `templates/`, and `install/` into your repo as `deploy/`.
2. Change `name`, `images`, `network.edge`, and `sites[]`.
3. Swap `app/` for your Dockerfiles; keep secrets only in `.env.example` placeholders.
4. Thin wrappers stay ~15 lines — they only set `INFRA_PROFILE` + `PACKAGECONFIG_URL` and exec `vibed-infra/install.sh`.

Schema: [`schema/packageconfig.md`](../../schema/packageconfig.md). Onboarding skill: [`skills/infra-packager/SKILL.md`](../../skills/infra-packager/SKILL.md).
