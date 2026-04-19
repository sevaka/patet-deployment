#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"
TARGET_RELEASE="${2:-}"

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"
PM2_ECOSYSTEM="/var/www/patet-deployment/ecosystem.config.js"

BACKEND_HEALTH_URL="http://127.0.0.1:57303/api/v1/auth/me"
FRONTEND_HEALTH_URL="http://127.0.0.1:4993/"

BACKEND_VERIFY_MAX_ATTEMPTS="${BACKEND_VERIFY_MAX_ATTEMPTS:-40}"
BACKEND_VERIFY_SLEEP_SECS="${BACKEND_VERIFY_SLEEP_SECS:-2}"

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
  echo "Verifying backend (retry while HTTP 000 — app still starting)"
  local attempt=1
  local code=""
  while [[ "$attempt" -le "$BACKEND_VERIFY_MAX_ATTEMPTS" ]]; do
    code="$(
      curl -sS -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 10 \
        "$BACKEND_HEALTH_URL" 2>/dev/null || true
    )"
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      echo "Backend looks up (HTTP $code) after attempt $attempt/$BACKEND_VERIFY_MAX_ATTEMPTS"
      return 0
    fi
    echo "  ... not ready (HTTP ${code:-000}), attempt $attempt/$BACKEND_VERIFY_MAX_ATTEMPTS — sleeping ${BACKEND_VERIFY_SLEEP_SECS}s"
    sleep "$BACKEND_VERIFY_SLEEP_SECS"
    attempt=$((attempt + 1))
  done
  echo "Backend verification failed after $BACKEND_VERIFY_MAX_ATTEMPTS attempts. Last HTTP code: ${code:-000}"
  exit 1
}

verify_frontend() {
  echo "Verifying frontend"
  echo "Manual check (same as this script): curl -fsS \"$FRONTEND_HEALTH_URL\""
  if ! curl -fsS "$FRONTEND_HEALTH_URL" >/dev/null; then
    echo "Frontend verification failed."
    echo "Retry manually: curl -fsS \"$FRONTEND_HEALTH_URL\""
    echo "With response headers: curl -fsSI \"$FRONTEND_HEALTH_URL\""
    exit 1
  fi
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



