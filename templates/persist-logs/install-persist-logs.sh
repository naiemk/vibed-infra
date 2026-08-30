#!/usr/bin/env bash
# One-time machine persist-logs dirs + shipper cron.
set -euo pipefail
PACKAGER="${PACKAGER_RAW:-$(cd "$(dirname "$0")/../.." && pwd)}"
ROOT="${VIBED_HOME:-${HOME}/services/vibed-infra}"
PDIR="${ROOT}/persist-logs"
mkdir -p "$PDIR"
cp -f "${PACKAGER}/lib/persistlog/ship.py" "$PDIR/ship.py" 2>/dev/null || true
mkdir -p "$PDIR/lib"
cp -rf "${PACKAGER}/lib/persistlog" "$PDIR/lib/" 2>/dev/null || true

if [[ ! -f "$PDIR/.env" ]]; then
  cat >"$PDIR/.env" <<EOF
PERSIST_LOG_ROOT=${PDIR}
PERSIST_SHIP=0
PERSIST_MACHINE_ID=
# R2_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com
# R2_BUCKET=vibed-logs
# R2_ACCESS_KEY_ID=
# R2_SECRET_ACCESS_KEY=
EOF
fi

MARKER="# vibed-persist-ship:${PDIR}"
CRON_LINE="*/10 * * * * cd ${PDIR} && set -a && . ${PDIR}/.env && set +a && python3 ${PDIR}/ship.py >/dev/null 2>&1 ${MARKER}"
if [[ -d /etc/cron.d && -w /etc/cron.d ]]; then
  cat >/etc/cron.d/vibed-persist-ship <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/10 * * * * root cd ${PDIR} && set -a && . ${PDIR}/.env && set +a && python3 ${PDIR}/ship.py >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/vibed-persist-ship
elif command -v crontab >/dev/null 2>&1; then
  existing="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | grep -vF "$MARKER" || true)"
  { printf '%s\n' "$filtered"; echo "$CRON_LINE"; } | sed '/^$/d' | crontab -
fi
echo "persist-logs ready at $PDIR (PERSIST_SHIP=0 until R2/S3 configured)"
