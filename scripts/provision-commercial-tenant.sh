#!/usr/bin/env bash
# Provision a commercial tenant on Server 2 (requires COMMERCIAL_MULTI_TENANT=true on API).
# Usage:
#   export PLATFORM_API=https://admin.yourplatform.com
#   export PLATFORM_ADMIN_TOKEN=eyJ...
#   ./scripts/provision-commercial-tenant.sh acme "Acme Logistics"

set -euo pipefail

SLUG="${1:?slug required (e.g. acme)}"
NAME="${2:?display name required}"
PLATFORM_API="${PLATFORM_API:?set PLATFORM_API e.g. https://admin.yourplatform.com}"
TOKEN="${PLATFORM_ADMIN_TOKEN:?set PLATFORM_ADMIN_TOKEN}"

curl -fsS -X POST "${PLATFORM_API}/api/v1/platform/tenants" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"slug\":\"${SLUG}\",\"name\":\"${NAME}\"}"

echo ""
echo "Tenant provisioned. Dashboard URL: https://${SLUG}.${PLATFORM_API#*://}"
