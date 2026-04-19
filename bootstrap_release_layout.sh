#!/usr/bin/env bash
set -euo pipefail

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"

echo "Creating release layout..."

mkdir -p "$API_ROOT/releases" "$API_ROOT/shared"
mkdir -p "$WEB_ROOT/releases" "$WEB_ROOT/shared"

if [ -f "$API_ROOT/.env" ] && [ ! -f "$API_ROOT/shared/.env" ]; then
  cp "$API_ROOT/.env" "$API_ROOT/shared/.env"
  echo "Copied backend .env to $API_ROOT/shared/.env"
fi

if [ -f "$WEB_ROOT/.env" ] && [ ! -f "$WEB_ROOT/shared/.env" ]; then
  cp "$WEB_ROOT/.env" "$WEB_ROOT/shared/.env"
  echo "Copied frontend .env to $WEB_ROOT/shared/.env"
fi

echo
echo "Done."
echo "Next:"
echo "1) put ecosystem.config.js into /var/www/deployment/"
echo "2) run deploy.sh backend"
echo "3) run deploy.sh frontend"

