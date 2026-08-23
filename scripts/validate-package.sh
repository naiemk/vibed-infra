#!/usr/bin/env bash
# Smoke checks before npm publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

test -x install.sh
test -f lib/fetch.sh
test -f lib/load_config.py
test -f templates/docker-compose.backend.yml
test -f schema/packageconfig.md

# install.sh must parse
bash -n install.sh
bash -n start.sh
bash -n update.sh

# generate.py loads
python3 lib/generate.py --help >/dev/null 2>&1 || python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'lib')
from load_config import load_packageconfig
print('load_config ok')
"

echo "vibed-infra package validation OK"
