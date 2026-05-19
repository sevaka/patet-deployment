#!/usr/bin/env bash
# Finalize a release uploaded from Windows (yarn install on Linux, symlink current, migrate, PM2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

finalize_usage() {
  echo "Finalize an uploaded Patet release (built on Windows, installed on Linux)."
  echo
  echo "Usage: $0 {backend|frontend|all} <release_timestamp> [options]"
  echo "  Example: $0 backend 2026-05-19_143022"
  echo "           $0 all 2026-05-19_143022"
  echo
  echo "Options:"
  echo "  --skip-migrate   Do not run backend migrations (default: run migrations on backend finalize)"
  echo "  -h, --help       Show this help and exit"
  echo
  echo "Environment:"
  echo "  PATET_WITH_BACKEND_MIGRATE=0|false   Same as --skip-migrate"
  echo "  PATET_API_ROOT, PATET_WEB_ROOT       Override app roots (see deploy-config.sh)"
}

WITH_BACKEND_MIGRATE=true
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --skip-migrate)
      WITH_BACKEND_MIGRATE=false
      ;;
    -h|--help)
      finalize_usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [[ "${PATET_WITH_BACKEND_MIGRATE:-}" == "0" || "${PATET_WITH_BACKEND_MIGRATE:-}" == "false" ]]; then
  WITH_BACKEND_MIGRATE=false
fi

ACTION="${POSITIONAL[0]:-}"
RELEASE_NAME="${POSITIONAL[1]:-}"

if [[ -z "$ACTION" || -z "$RELEASE_NAME" ]]; then
  finalize_usage
  exit 1
fi

migrate_flag=false
[[ "$WITH_BACKEND_MIGRATE" == "true" ]] && migrate_flag=true

case "$ACTION" in
  backend)
    patet_finalize_uploaded_backend "$RELEASE_NAME" "$migrate_flag"
    ;;
  frontend)
    patet_finalize_uploaded_frontend "$RELEASE_NAME"
    ;;
  all)
    patet_finalize_uploaded_backend "$RELEASE_NAME" "$migrate_flag"
    patet_finalize_uploaded_frontend "$RELEASE_NAME"
    ;;
  *)
    echo "Unknown action: $ACTION"
    finalize_usage
    exit 1
    ;;
esac

echo
echo "Done."
