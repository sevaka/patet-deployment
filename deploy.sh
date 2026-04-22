#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

ACTION="${1:-}"
STATUS_SCOPE="${2:-all}"

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"

API_REPO="git@bitbucket.org:we-dotech/patet-back-nestjs.git"
WEB_REPO="git@bitbucket.org:we-dotech/patet-website.git"

API_BRANCH="sevak_develop"
WEB_BRANCH="develop_intermediate"

PM2_ECOSYSTEM="/var/www/patet-deployment/ecosystem.config.js"

BACKEND_HEALTH_URL="http://127.0.0.1:57303/api/v1/auth/me"
FRONTEND_HEALTH_URL="http://127.0.0.1:4993/"

# After pm2 restart, Nest may not listen immediately; curl then reports HTTP 000 (connection failed).
BACKEND_VERIFY_MAX_ATTEMPTS="${BACKEND_VERIFY_MAX_ATTEMPTS:-40}"
BACKEND_VERIFY_SLEEP_SECS="${BACKEND_VERIFY_SLEEP_SECS:-2}"

KEEP_DISTINCT_SUCCESSFUL_SHAS="${KEEP_DISTINCT_SUCCESSFUL_SHAS:-5}"

BACKEND_SHARED_FILES=(
  ".env"
  "ca-certificate.crt"
)

FRONTEND_SHARED_FILES=(
  ".env"
)

deploy_usage() {
  echo "Patet production deploy (clone/build, swap current, PM2, health check)."
  echo
  echo "Usage: $0 {backend|frontend|all|status} [scope_for_status]"
  echo "  Deploy: $0 backend|frontend|all"
  echo "  Status: $0 status [backend|frontend|all]  — git SHA, commit date, deploy meta for live release"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help and exit"
}

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  deploy_usage
  exit 0
fi

if [[ -z "$ACTION" ]]; then
  deploy_usage
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

remove_non_yarn_lockfiles() {
  local release_dir="$1"
  local lockfile

  for lockfile in "package-lock.json" "npm-shrinkwrap.json"; do
    if [[ -f "$release_dir/$lockfile" ]]; then
      echo "Removing $lockfile from release (Yarn-only installs)"
      rm -f "$release_dir/$lockfile"
    fi
  done
}

verify_backend() {
  log "Verifying backend (will retry while HTTP is 000 or empty — app still starting)"
  local attempt=1
  local code=""
  while [[ "$attempt" -le "$BACKEND_VERIFY_MAX_ATTEMPTS" ]]; do
    code="$(
      curl -sS -o /dev/null -w "%{http_code}" \
        --connect-timeout 3 --max-time 10 \
        "$BACKEND_HEALTH_URL" 2>/dev/null || true
    )"
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      echo "Backend looks up (HTTP $code from /api/v1/auth/me) after attempt $attempt/$BACKEND_VERIFY_MAX_ATTEMPTS"
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
  log "Verifying frontend"
  echo "Manual check (same as this script): curl -fsS \"$FRONTEND_HEALTH_URL\""
  if ! curl -fsS "$FRONTEND_HEALTH_URL" >/dev/null; then
    echo "Frontend verification failed."
    echo "Retry manually: curl -fsS \"$FRONTEND_HEALTH_URL\""
    echo "With response headers: curl -fsSI \"$FRONTEND_HEALTH_URL\""
    exit 1
  fi
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

  # Snapshot the currently-running release BEFORE the symlink swap
  local _old_backend_info
  local _old_backend_dir
  _old_backend_dir="$(readlink -f "$API_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_backend_info "Backend (patet-api)" "$_old_backend_dir"

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

  if pm2 describe patet-api > /dev/null 2>&1; then
    pm2 startOrRestart "$PM2_ECOSYSTEM" --only patet-api --update-env
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-api --update-env
  fi

  verify_backend
  write_patet_release_meta "$release_dir" backend
  cleanup_releases_keep_distinct_successful_sha "$API_ROOT" "$KEEP_DISTINCT_SUCCESSFUL_SHAS" backend

  echo "Backend deploy complete: $release_dir"
  echo
  echo "==== Changed from: Backend (patet-api) release ===="
  echo "$_old_backend_info" | grep -v '^====' || true
  echo
  echo "==== New Running: Backend (patet-api) release ===="
  _build_release_git_info_lines "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"
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

  # Snapshot the currently-running release BEFORE the symlink swap
  local _old_frontend_info
  local _old_frontend_dir
  _old_frontend_dir="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_frontend_info "Frontend (patet-website)" "$_old_frontend_dir"

  log "Deploying frontend release $release"
  git clone --branch "$WEB_BRANCH" --single-branch "$WEB_REPO" "$release_dir"

  if [ ! -f "$WEB_ROOT/shared/.env" ]; then
    echo "Missing frontend shared env: $WEB_ROOT/shared/.env"
    exit 1
  fi

  symlink_shared_files "$WEB_ROOT/shared" "$release_dir" "${FRONTEND_SHARED_FILES[@]}"

  cd "$release_dir"
  remove_non_yarn_lockfiles "$release_dir"

  # Fresh output dir so a partial/corrupt .next from a killed build cannot pass as success.
  rm -rf "$release_dir/.next"

  export NODE_ENV=production
  # On low-memory VPS builds can be SIGKILL'd mid-write; increase heap, e.g.:
  #   export NEXT_BUILD_NODE_OPTIONS="--max-old-space-size=4096"
  if [[ -n "${NEXT_BUILD_NODE_OPTIONS:-}" ]]; then
    export NODE_OPTIONS="${NEXT_BUILD_NODE_OPTIONS}"
  fi

  yarn install --non-interactive

  local build_rc=0
  yarn build || build_rc=$?

  if [[ "${build_rc:-0}" -ne 0 ]]; then
    echo "ERROR: yarn build exited with code ${build_rc}. Fix compile/type errors above."
    exit 1
  fi

  if [[ ! -f "$release_dir/.next/BUILD_ID" ]]; then
    echo "ERROR: next build did not produce a production output (missing $release_dir/.next/BUILD_ID)."
    echo "Typical causes: Linux OOM killer (check dmesg), disk full, or Node killed before finalize."
    echo "Disk space:" && df -h "$release_dir" || true
    echo "Memory:" && free -h 2>/dev/null || true
    echo "Next.js version from package.json:"
    node -p "require('./package.json').dependencies.next" 2>/dev/null || echo "  (could not read)"
    echo "Listing .next if present:"
    ls -la "$release_dir/.next" 2>/dev/null || echo "  (no .next directory)"
    echo "BUILD_ID search:"
    find "$release_dir/.next" -name BUILD_ID -print 2>/dev/null || true
    exit 1
  fi

  ln -sfn "$release_dir" "$WEB_ROOT/current"
  echo "Frontend current -> $(readlink -f "$WEB_ROOT/current")"

  if pm2 describe patet-website >/dev/null 2>&1; then
    pm2 startOrReload "$PM2_ECOSYSTEM" --only patet-website --update-env
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-website --update-env
  fi

  verify_frontend
  write_patet_release_meta "$release_dir" frontend
  cleanup_releases_keep_distinct_successful_sha "$WEB_ROOT" "$KEEP_DISTINCT_SUCCESSFUL_SHAS" frontend

  echo "Frontend deploy complete: $release_dir"
  echo
  echo "==== Changed from: Frontend (patet-website) release ===="
  echo "$_old_frontend_info" | grep -v '^====' || true
  echo
  echo "==== New Running: Frontend (patet-website) release ===="
  _build_release_git_info_lines "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
}

case "$ACTION" in
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
  status)
    case "$STATUS_SCOPE" in
      backend)
        print_patet_running_release "$API_ROOT" "Backend (patet-api)"
        ;;
      frontend)
        print_patet_running_release "$WEB_ROOT" "Frontend (patet-website)"
        ;;
      all)
        print_patet_running_release "$API_ROOT" "Backend (patet-api)"
        print_patet_running_release "$WEB_ROOT" "Frontend (patet-website)"
        ;;
      *)
        echo "Invalid status scope: $STATUS_SCOPE"
        echo "Usage: $0 status [backend|frontend|all]"
        deploy_usage
        exit 1
        ;;
    esac
    echo
    echo "Done."
    exit 0
    ;;
  *)
    echo "Unknown action: $ACTION"
    deploy_usage
    exit 1
    ;;
esac

echo
echo "Done."


