#!/usr/bin/env bash
set -euo pipefail

API_ROOT="/var/www/patet-api"

if [ ! -L "$API_ROOT/current" ]; then
  echo "Backend current symlink does not exist."
  exit 1
fi

cd "$API_ROOT/current"
yarn migration:run
echo "Backend migrations completed."


