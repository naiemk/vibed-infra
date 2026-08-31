---
name: agent-vps-prep
description: >-
  Prepare a fresh VPS for vibed-infra installs run by an automation agent
  (cloud_agent): SSH key, sudoers, Docker group, firewall; app data uses named volumes.
---

# Prepare a VPS for vibed-infra (agent operator)

## Who this is for

Non-root user (e.g. `cloud_agent`) that will run `wget …/dist/install-*.sh | bash`,
`setup-tls.sh` (docker certbot), and `start-*.sh` without interactive sudo.

## 1. Create the operator user

**Preferred (configure once):** create the operator as **uid/gid 1000** so bind mounts match typical `USER node` images — no chown, no ACL, no per-app commands forever.

(as root — only if uid/gid 1000 are free: `getent passwd 1000`; `getent group 1000`)

```bash
adduser --disabled-password --gecos "" --uid 1000 cloud_agent
# if group 1000 already named "node", either:
#   adduser --uid 1000 --gid 1000 ...
# or rename/reuse that group carefully
groupmod -n cloud_agent node 2>/dev/null || true  # only if appropriate on that host

mkdir -p /home/cloud_agent/.ssh
chmod 700 /home/cloud_agent/.ssh
# paste agent public key:
echo 'ssh-ed25519 AAAA… cloud_agent' >> /home/cloud_agent/.ssh/authorized_keys
chmod 600 /home/cloud_agent/.ssh/authorized_keys
chown -R cloud_agent:cloud_agent /home/cloud_agent/.ssh
```

If `adduser --uid 1000` fails because 1000 is taken by a `node` user from a package:

- **Option A:** use that existing uid-1000 user as the agent (add docker group + SSH key to it)
- **Option B:** create `cloud_agent` with a different uid and use the **ACL fallback** in §5

## 2. SSH from the agent machine

Generate a key if needed, then connect with `StrictHostKeyChecking=accept-new`:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/cloud_agent_vps -N ""
ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/cloud_agent_vps cloud_agent@VPS_IP
```

## 3. Install Docker + add user to docker group

```bash
# as root — use distro docs or https://get.docker.com
usermod -aG docker cloud_agent
# cloud_agent must re-login for group to apply
```

Verify as `cloud_agent`: `docker ps` (no sudo).

## 4. Home ownership

If home was created oddly (root-owned `$HOME`):

```bash
sudo chown -R cloud_agent:cloud_agent /home/cloud_agent
```

vibed-infra defaults: `~/services/gateway`, `~/services/vibed-infra`, product dirs under `~/services/<app>/`.

## 5. App data ownership — named volumes (default)

API data, persist logs, and worker logs use **Docker named volumes** by default (`{container}-data`, `{container}-persist`, `{container}-logs`). They are not under `~/services`, so the operator does **not** chown them to uid 1000 and does not need a `u:1000` ACL for SQLite/WALs.

In-volume ownership comes from the **app image** on first empty mount. Digest-gated recreates remount the same volume — the database is not wiped.

### Inspect data / logs over SSH

```bash
~/services/vibed-infra/monitor-vibed.sh
# non-interactive:
~/services/vibed-infra/monitor-vibed.sh --list
~/services/vibed-infra/monitor-vibed.sh --summary myapp-api
```

Or:

```bash
docker run --rm -v myapp-api-data:/data:ro alpine ls -la /data
docker run --rm -v myapp-api-persist:/persist-logs:ro alpine ls -laR /persist-logs
```

### Optional: bind-mount escape hatch

`DATA_BIND=1` / `PERSIST_LOG_BIND=1` / `LOGS_BIND=1` with a host path. Only then does host uid matter for those dirs. Prefer named volumes.

### Install-dir scripts under `~/services`

Gateway certs, product `.env`, and yaml configs still live under `~/services`. Prefer operator uid 1000 **or** a one-time ACL on `~/services` so the agent can write install trees — not for app SQLite.

```bash
# optional ACL for install scripts only (operator not uid 1000)
apt-get install -y acl
install -d -o cloud_agent -g cloud_agent /home/cloud_agent/services
setfacl -m u:cloud_agent:rwx -d -m u:cloud_agent:rwx /home/cloud_agent/services
```

## 6. Ports + DNS

- Free **80/443** for the host gateway (only vps-gateway binds them)
- Point DNS A records at `gateway.publicIp` before `setup-tls.sh` (Let’s Encrypt)

## 7. TLS (no host certbot required)

With Docker, `setup-tls.sh` uses `certbot/certbot` and writes PEMs under `~/services/gateway/certs/`. No sudo needed for LE when docker works. See [system-gateway](../system-gateway/SKILL.md).

## 8. First product install

```bash
export INSTALL_DIR=$HOME/services/myapp/api
mkdir -p "$INSTALL_DIR"
wget -qO- https://raw.githubusercontent.com/ORG/REPO/main/deploy/.../dist/install-api.sh | bash
# edit .env, then ./start-api.sh
# repeat ui, nodes, gateway
```

**Important:** `export INSTALL_DIR=...` before the pipe — `INSTALL_DIR=... wget | bash` does **not** pass the var into bash.

## 9. Checklist

- [ ] `ssh cloud_agent@VPS` works with key only
- [ ] `docker ps` works without sudo
- [ ] `$HOME` owned by `cloud_agent`
- [ ] DNS → VPS IP
- [ ] install-gateway + setup-tls + start-gateway
- [ ] `~/services/vibed-infra/monitor-vibed.sh --list` shows deployments after start
