#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"
TARGET_RELEASE="${2:-}"

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"
PM2_ECOSYSTEM="/var/www/patet-deployment/ecosystem.config.js"

BACKEND_HEALTH_URL="http://127.0.0.1:57303/api/v1/auth/me"
FRONTEND_HEALTH_URL="http://127.0.0.1:4993/"

if [[ -z "$COMPONENT" ]]; then
  echo "Usage: $0 {backend|frontend|all} [release_name]"
  exit 1
fi

log() {
  echo
  echo "==== $* ===="
}

get_previous_release() {
  local root="$1"
  local current_real
  current_real="$(readlink -f "$root/current" 2>/dev/null || true)"

  mapfile -t releases < <(ls -1dt "$root"/releases/* 2>/dev/null || true)

  for r in "${releases[@]}"; do
    if [[ "$(readlink -f "$r")" != "$current_real" ]]; then
      basename "$r"
      return 0
    fi
  done

  return 1
}

verify_backend() {
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_HEALTH_URL" || true)"
  if [[ "$code" == "200" || "$code" == "401" ]]; then
    echo "Backend looks up (HTTP $code)"
    return 0
  fi
  echo "Backend verification failed. HTTP code: $code"
  exit 1
}

verify_frontend() {
  curl -fsS "$FRONTEND_HEALTH_URL" >/dev/null
  echo "Frontend looks up."
}

rollback_one() {
  local root="$1"
  local pm2_name="$2"
  local mode="$3"
  local release_name="$4"

  local target
  if [[ -n "$release_name" ]]; then
    target="$root/releases/$release_name"
    if [[ ! -d "$target" ]]; then
      echo "Release not found: $target"
      exit 1
    fi
  else
    local prev
    prev="$(get_previous_release "$root")" || {
      echo "No previous release found for $root"
      exit 1
    }
    target="$root/releases/$prev"
  fi

  ln -sfn "$target" "$root/current"
  echo "$root current -> $(readlink -f "$root/current")"

  if [[ "$mode" == "reload" ]]; then
    pm2 startOrReload "$PM2_ECOSYSTEM" --only "$pm2_name" --update-env
  else
    pm2 startOrRestart "$PM2_ECOSYSTEM" --only "$pm2_name" --update-env
  fi
}

case "$COMPONENT" in
  backend)
    log "Rolling back backend"
    rollback_one "$API_ROOT" "patet-api" "restart" "$TARGET_RELEASE"
    verify_backend
    ;;
  frontend)
    log "Rolling back frontend"
    rollback_one "$WEB_ROOT" "patet-website" "reload" "$TARGET_RELEASE"
    verify_frontend
    ;;
  all)
    log "Rolling back backend"
    rollback_one "$API_ROOT" "patet-api" "restart" "$TARGET_RELEASE"
    verify_backend

    log "Rolling back frontend"
    rollback_one "$WEB_ROOT" "patet-website" "reload" "$TARGET_RELEASE"
    verify_frontend
    ;;
  *)
    echo "Usage: $0 {backend|frontend|all} [release_name]"
    exit 1
    ;;
esac

echo
echo "Rollback completed."



