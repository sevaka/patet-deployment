#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

deploy_usage() {
  echo "Patet production deploy (clone/build, swap current, PM2, health check)."
  echo
  echo "Usage: $0 {backend|frontend|all|status} [scope_for_status] [options]"
  echo "  Deploy: $0 backend|frontend|all [--with-migrate]"
  echo "  Status: $0 status [backend|frontend|all]  — git SHA, commit date, deploy meta for live release"
  echo
  echo "Options:"
  echo "  --with-migrate   After a successful backend build, run migrations on current, then pm2 reload"
  echo "                   (backend / all only). Default: migrations are not run by deploy."
  echo "  -h, --help       Show this help and exit"
  echo
  echo "Environment:"
  echo "  PATET_WITH_BACKEND_MIGRATE=1|true   Same as --with-migrate (for backend deploy)"
  echo "  PATET_BUILD_SCALE_PM2_DOWN=0        Skip PM2 scale to 1 before build (default: scale down/up; errors ignored)"
  echo "  BUILD_MEM_MAX=2G                    Default build RAM cap (frontend deploy; backend uses script default)"
  echo "  BUILD_CPU_MAX_PERCENT=40            Default build CPU % per logical CPU (in app package.json scripts)"
  echo
  echo "Windows artifact deploy: see deploy-from-windows.ps1 and finalize-release.sh"
}

WITH_BACKEND_MIGRATE=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --with-migrate)
      WITH_BACKEND_MIGRATE=true
      ;;
    -h|--help)
      deploy_usage
      exit 0
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [[ "${PATET_WITH_BACKEND_MIGRATE:-}" == "1" || "${PATET_WITH_BACKEND_MIGRATE:-}" == "true" ]]; then
  WITH_BACKEND_MIGRATE=true
fi

ACTION="${POSITIONAL[0]:-}"
STATUS_SCOPE="${POSITIONAL[1]:-all}"

if [[ -z "$ACTION" ]]; then
  deploy_usage
  exit 1
fi

deploy_backend() {
  require_cmd git
  require_cmd yarn
  require_cmd pm2
  require_cmd curl

  local release
  release="$(patet_timestamp)"
  local release_dir="$API_ROOT/releases/$release"
  local _old_backend_info _old_backend_dir
  local build_rc=0

  _old_backend_dir="$(readlink -f "$API_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_backend_info "Backend (patet-api)" "$_old_backend_dir"

  patet_log "Deploying backend release $release"
  prepare_pm2_for_build
  trap restore_pm2_cluster_sizes EXIT

  git clone --branch "$API_BRANCH" --single-branch "$API_REPO" "$release_dir"
  ensure_backend_shared_env
  symlink_shared_files "$API_ROOT/shared" "$release_dir" "${BACKEND_SHARED_FILES[@]}"

  cd "$release_dir"
  export BUILD_MEM_MAX="${BUILD_MEM_MAX:-2G}"
  export BUILD_CPU_MAX_PERCENT="${BUILD_CPU_MAX_PERCENT:-40}"
  yarn install

  yarn build || build_rc=$?
  if [[ "${build_rc:-0}" -ne 0 ]]; then
    echo "ERROR: backend yarn build exited with code ${build_rc}. Skipping migrate and PM2 reload."
    exit 1
  fi

  restore_pm2_cluster_sizes
  trap - EXIT

  local migrate_flag=false
  [[ "$WITH_BACKEND_MIGRATE" == "true" ]] && migrate_flag=true
  patet_activate_backend_release "$release_dir" "$migrate_flag"

  echo "Backend deploy complete: $release_dir"
  echo
  echo "==== Changed from: Backend (patet-api) release ===="
  echo "$_old_backend_info" | grep -v '^====' || true
  echo
  echo "==== New Running: Backend (patet-api) release ===="
  _build_release_git_info_lines "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"
}

deploy_frontend() {
  require_cmd git
  require_cmd yarn
  require_cmd pm2
  require_cmd curl

  local release
  release="$(patet_timestamp)"
  local release_dir="$WEB_ROOT/releases/$release"
  local _old_frontend_info _old_frontend_dir
  local build_rc=0

  _old_frontend_dir="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_frontend_info "Frontend (patet-website)" "$_old_frontend_dir"

  patet_log "Deploying frontend release $release"
  prepare_pm2_for_build
  trap restore_pm2_cluster_sizes EXIT

  git clone --branch "$WEB_BRANCH" --single-branch "$WEB_REPO" "$release_dir"
  ensure_frontend_shared_env
  symlink_shared_files "$WEB_ROOT/shared" "$release_dir" "${FRONTEND_SHARED_FILES[@]}"

  cd "$release_dir"
  remove_non_yarn_lockfiles "$release_dir"
  rm -rf "$release_dir/.next"

  export NODE_ENV=production
  export BUILD_MEM_MAX="${BUILD_MEM_MAX:-2G}"
  export BUILD_CPU_MAX_PERCENT="${BUILD_CPU_MAX_PERCENT:-40}"
  if [[ -n "${NEXT_BUILD_NODE_OPTIONS:-}" ]]; then
    export NODE_OPTIONS="${NEXT_BUILD_NODE_OPTIONS}"
  fi

  yarn install --non-interactive
  yarn build || build_rc=$?

  if [[ "${build_rc:-0}" -ne 0 ]]; then
    echo "ERROR: yarn build exited with code ${build_rc}. Fix compile/type errors above."
    exit 1
  fi

  restore_pm2_cluster_sizes
  trap - EXIT

  patet_activate_frontend_release "$release_dir"

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
