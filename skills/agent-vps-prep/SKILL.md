---
name: agent-vps-prep
description: >-
  Prepare a fresh VPS for vibed-infra installs run by an automation agent
  (cloud_agent): SSH key, sudoers, Docker group, data-dir ownership, firewall.
---

# Prepare a VPS for vibed-infra (agent operator)

## Who this is for

Non-root user (e.g. `cloud_agent`) that will run `wget …/dist/install-*.sh | bash`,
`setup-tls.sh` (docker certbot), and `start-*.sh` without interactive sudo.

## 1. Create the operator user

(as root)

```bash
adduser --disabled-password --gecos "" cloud_agent
mkdir -p /home/cloud_agent/.ssh
chmod 700 /home/cloud_agent/.ssh
# paste agent public key:
echo 'ssh-ed25519 AAAA… cloud_agent' >> /home/cloud_agent/.ssh/authorized_keys
chmod 600 /home/cloud_agent/.ssh/authorized_keys
chown -R cloud_agent:cloud_agent /home/cloud_agent/.ssh
```

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

## 5. Container data directory ownership (uid 1000)

Product images often run as `node` (uid/gid **1000**). Bind-mounted `./data` and `./logs` created by `cloud_agent` (e.g. uid 1001) cause `SQLITE_CANTOPEN` / `EACCES`.

**One-shot after first install (or before first start), as root/sudo:**

```bash
# Trustless Commerce / typical vibed apps — adjust paths to your INSTALL_DIRs
sudo chown -R 1000:1000 \
  /home/cloud_agent/services/*/api/data \
  /home/cloud_agent/services/*/api/persist-logs \
  /home/cloud_agent/services/*/nodes/logs
```

Or per product:

```bash
sudo chown -R 1000:1000 ~/services/tctest/api/data ~/services/tctest/api/persist-logs
sudo chown -R 1000:1000 ~/services/tcmain/api/data ~/services/tcmain/api/persist-logs
sudo chown -R 1000:1000 ~/services/tctest/nodes/logs ~/services/tcmain/nodes/logs
```

Optional: allow passwordless chown for the agent (tight sudoers):

```bash
# /etc/sudoers.d/cloud_agent-chown
cloud_agent ALL=(root) NOPASSWD: /usr/bin/chown -R 1000\:1000 /home/cloud_agent/services/*
```

Prefer the explicit one-shot; sudoers is optional.

Note: start scripts may try `sudo chown` or a docker alpine chown — host sudo still helps for empty dirs created as the operator user.

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
- [ ] uid 1000 chown on data/logs after first mkdir/install
- [ ] DNS → VPS IP
- [ ] install-gateway + setup-tls + start-gateway
