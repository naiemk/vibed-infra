#!/usr/bin/env bash
# Self-signed certs for a lab VPS or local try. Not for production.
set -euo pipefail
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/certs}"
HOST="${HELLO_HOST:-hello.example.com}"
mkdir -p "$DEST"
openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
  -keyout "$DEST/privkey.pem" \
  -out "$DEST/fullchain.pem" \
  -subj "/CN=${HOST}" \
  -addext "subjectAltName=DNS:${HOST},DNS:www.${HOST},DNS:localhost"
chmod 644 "$DEST/fullchain.pem"
chmod 600 "$DEST/privkey.pem"
echo "Wrote $DEST/fullchain.pem and $DEST/privkey.pem"
echo "Point TLS_FULLCHAIN / TLS_PRIVKEY in the gateway .env at these files."
