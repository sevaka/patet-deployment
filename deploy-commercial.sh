#!/usr/bin/env bash
# Deploy to commercial SaaS (Server 2) using profiles/commercial.env
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/deploy-from-linux.sh" --profile commercial "$@"
