#!/usr/bin/env bash
# Deploy to patet.am (Server 1) using profiles/patet-am.env
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/deploy-from-linux.sh" --profile patet-am "$@"
