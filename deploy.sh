#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"

API_REPO="git@bitbucket.org:we-dotech/patet-back-nestjs.git"
WEB_REPO="git@bitbucket.org:we-dotech/patet-website.git"

API_BRANCH="sevak_develop"
WEB_BRANCH="develop_intermediate"

PM2_ECOSYSTEM="/var/www/patet-deployment/ecosystem.config.js"

BACKEND_HEALTH_URL="http://127.0.0.1:57303/api/v1/auth/me"
FRONTEND_HEALTH_URL="http://127.0.0.1:4993/"

KEEP_RELEASES=5

BACKEND_SHARED_FILES=(
  ".env"
  "ca-certificate.crt"
)

FRONTEND_SHARED_FILES=(
  ".env"
)

if [[ -z "$COMPONENT" ]]; then
  echo "Usage: $0 {backend|frontend|all}"
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

log() {
  echo
  echo "==== $* ===="
}

timestamp() {
  date +"%Y-%m-%d_%H%M%S"
}

cleanup_old_releases() {
  local root="$1"
  local keep="$2"

  if [ ! -d "$root/releases" ]; then
    return 0
  fi

  mapfile -t releases < <(ls -1dt "$root"/releases/* 2>/dev/null || true)

  if [ "${#releases[@]}" -le "$keep" ]; then
    return 0
  fi

  for old in "${releases[@]:$keep}"; do
    echo "Removing old release: $old"
    rm -rf "$old"
  done
}

verify_backend() {
  log "Verifying backend"
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_HEALTH_URL" || true)"
  if [[ "$code" == "200" || "$code" == "401" ]]; then
    echo "Backend looks up (HTTP $code from /api/v1/auth/me)"
    return 0
  fi
  echo "Backend verification failed. HTTP code: $code"
  exit 1
}

verify_frontend() {
  log "Verifying frontend"
  curl -fsS "$FRONTEND_HEALTH_URL" >/dev/null
  echo "Frontend looks up."
}

deploy_backend() {
  require_cmd git
  require_cmd yarn
  require_cmd pm2
  require_cmd curl

  local release
  release="$(timestamp)"
  local release_dir="$API_ROOT/releases/$release"

  log "Deploying backend release $release"
  git clone --branch "$API_BRANCH" --single-branch "$API_REPO" "$release_dir"

  if [ ! -f "$API_ROOT/shared/.env" ]; then
    echo "Missing backend shared env: $API_ROOT/shared/.env"
    exit 1
  fi

  symlink_shared_files "$API_ROOT/shared" "$release_dir" "${BACKEND_SHARED_FILES[@]}"

  cd "$release_dir"
  yarn install
  yarn build

  ln -sfn "$release_dir" "$API_ROOT/current"
  echo "Backend current -> $(readlink -f "$API_ROOT/current")"

  if pm2 describe patet-api >/dev/null 2>&1; then
    pm2 startOrRestart "$PM2_ECOSYSTEM" --only patet-api --update-env
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-api --update-env
  fi

  verify_backend
  cleanup_old_releases "$API_ROOT" "$KEEP_RELEASES"

  echo "Backend deploy complete: $release_dir"
}

symlink_shared_files() {
  local shared_dir="$1"
  local release_dir="$2"
  shift 2
  local files=("$@")

  for f in "${files[@]}"; do
    if [ ! -e "$shared_dir/$f" ]; then
      echo "Missing shared file: $shared_dir/$f"
      exit 1
    fi
    ln -sfn "$shared_dir/$f" "$release_dir/$f"
  done
}

deploy_frontend() {
  require_cmd git
  require_cmd yarn
  require_cmd pm2
  require_cmd curl

  local release
  release="$(timestamp)"
  local release_dir="$WEB_ROOT/releases/$release"

  log "Deploying frontend release $release"
  git clone --branch "$WEB_BRANCH" --single-branch "$WEB_REPO" "$release_dir"

  if [ ! -f "$WEB_ROOT/shared/.env" ]; then
    echo "Missing frontend shared env: $WEB_ROOT/shared/.env"
    exit 1
  fi

  symlink_shared_files "$WEB_ROOT/shared" "$release_dir" "${FRONTEND_SHARED_FILES[@]}"

  cd "$release_dir"
  yarn install
  yarn build

  ln -sfn "$release_dir" "$WEB_ROOT/current"
  echo "Frontend current -> $(readlink -f "$WEB_ROOT/current")"

  if pm2 describe patet-website >/dev/null 2>&1; then
    pm2 startOrReload "$PM2_ECOSYSTEM" --only patet-website --update-env
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-website --update-env
  fi

  verify_frontend
  cleanup_old_releases "$WEB_ROOT" "$KEEP_RELEASES"

  echo "Frontend deploy complete: $release_dir"
}

case "$COMPONENT" in
  backend)
    deploy_backend
    ;;
  frontend)
    deploy_frontend
    ;;
  all)
    deploy_backend
    deploy_frontend
    ;;
  *)
    echo "Usage: $0 {backend|frontend|all}"
    exit 1
    ;;
esac

echo
echo "Done."
echo "Current backend:  $(readlink -f "$API_ROOT/current" 2>/dev/null || true)"
echo "Current frontend: $(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"


