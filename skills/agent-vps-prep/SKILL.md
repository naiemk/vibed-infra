---
name: agent-vps-prep
description: >-
  Prepare a fresh VPS for vibed-infra installs run by an automation agent
  (cloud_agent): SSH key, sudoers, Docker group, one-time uid-1000/ACL ownership, firewall.
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

## 5. Bind-mount ownership (uid 1000) — configure once

Product images often run as `node` (uid/gid **1000**). If the operator creates `./data` / `./logs` as a *different* uid, containers hit `SQLITE_CANTOPEN` / `EACCES`. Fix this **once on the host**, not after every product install.

### Preferred: operator is already uid 1000

If §1 created `cloud_agent` as uid/gid 1000, new trees under `~/services` are already writable by the container user. Nothing else to do.

### Fallback (configure once on `~/services`): default ACL

When the operator is **not** uid 1000, grant uid 1000 rwx on every new file under services regardless of who creates it. Requires the `acl` package.

```bash
# as root, once after creating cloud_agent (any uid)
apt-get install -y acl
install -d -o cloud_agent -g cloud_agent /home/cloud_agent/services
setfacl -m u:1000:rwx /home/cloud_agent/services
setfacl -d -m u:1000:rwx /home/cloud_agent/services
# also grant the operator full access via ACL defaults
setfacl -m u:cloud_agent:rwx /home/cloud_agent/services
setfacl -d -m u:cloud_agent:rwx /home/cloud_agent/services
```

### Recovery only

If someone already created wrong-owned dirs **before** uid-1000 or ACL setup:

```bash
sudo chown -R 1000:1000 \
  /home/cloud_agent/services/*/api/data \
  /home/cloud_agent/services/*/api/persist-logs \
  /home/cloud_agent/services/*/nodes/logs
```

Do not rely on per-product `chown` as ongoing ops. Prefer fixing the host model above.

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
- [ ] operator uid is 1000 **OR** `~/services` has default ACL for `u:1000` (and `u:cloud_agent` if needed)
- [ ] DNS → VPS IP
- [ ] install-gateway + setup-tls + start-gateway
