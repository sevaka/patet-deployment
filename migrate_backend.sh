#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

if [ ! -L "$API_ROOT/current" ]; then
  echo "Backend current symlink does not exist."
  exit 1
fi

cd "$API_ROOT/current"
yarn migration:run
echo "Backend migrations completed."


