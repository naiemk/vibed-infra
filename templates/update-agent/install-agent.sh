#!/usr/bin/env bash
# Install once-per-machine serial update agent + cron consumer.
set -euo pipefail
PACKAGER="${PACKAGER_RAW:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
if [[ -f "${PACKAGER}/lib/update_queue.sh" ]]; then
  source "${PACKAGER}/lib/update_queue.sh"
elif [[ -f "${SCRIPT_DIR}/../../lib/update_queue.sh" ]]; then
  source "${SCRIPT_DIR}/../../lib/update_queue.sh"
else
  echo "update_queue.sh not found" >&2
  exit 1
fi

HOME_AGENT="$(vibed_queue_dirs)"
mkdir -p "$HOME_AGENT/lib"
cp -f "${PACKAGER}/lib/update_queue.sh" "$HOME_AGENT/lib/update_queue.sh"
cp -f "${SCRIPT_DIR}/agent.sh" "$HOME_AGENT/agent.sh"
cp -f "${SCRIPT_DIR}/webhook_server.py" "$HOME_AGENT/webhook_server.py"
cp -f "${SCRIPT_DIR}/enqueue.sh" "$HOME_AGENT/enqueue.sh"
chmod +x "$HOME_AGENT/agent.sh" "$HOME_AGENT/enqueue.sh"

if [[ ! -f "$HOME_AGENT/.env" ]]; then
  cat >"$HOME_AGENT/.env" <<EOF
WEBHOOK_SECRET=change-me-webhook-secret
WEBHOOK_PORT=19200
EOF
fi

MARKER="# vibed-update-agent:${HOME_AGENT}"
CRON_LINE="*/5 * * * * cd ${HOME_AGENT} && /bin/bash ${HOME_AGENT}/agent.sh >/dev/null 2>&1 ${MARKER}"
CRON_D="/etc/cron.d/vibed-update-agent"

if [[ -d /etc/cron.d && -w /etc/cron.d ]]; then
  cat >"$CRON_D" <<EOF
# Managed by vibed-infra update-agent
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/5 * * * * root cd ${HOME_AGENT} && /bin/bash ${HOME_AGENT}/agent.sh >/dev/null 2>&1
EOF
  chmod 644 "$CRON_D"
  echo "installed $CRON_D"
elif command -v crontab >/dev/null 2>&1; then
  existing="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | grep -vF "$MARKER" || true)"
  { printf '%s\n' "$filtered"; echo "$CRON_LINE"; } | sed '/^$/d' | crontab -
  echo "installed user cron for update-agent"
fi

# Optional: start webhook in background if not running
if command -v python3 >/dev/null 2>&1; then
  if ! pgrep -f "webhook_server.py" >/dev/null 2>&1; then
    nohup python3 "$HOME_AGENT/webhook_server.py" >>"$HOME_AGENT/webhook.log" 2>&1 &
    echo "started webhook_server.py (port from .env)"
  fi
fi

echo "update-agent ready at $HOME_AGENT"
