#!/usr/bin/env bash
# Shared helpers for deploy.sh, finalize-release.sh, and rollback.sh (source this file; do not execute directly).

_DEPLOY_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-config.sh
source "$_DEPLOY_COMMON_DIR/deploy-config.sh"

# Non-interactive SSH (e.g. deploy-from-windows.ps1) does not load login profiles; nvm is common on Patet VPS.
patet_ensure_node_in_path() {
  if command -v node >/dev/null 2>&1 && command -v yarn >/dev/null 2>&1; then
    return 0
  fi
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
  fi
}
patet_ensure_node_in_path

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

patet_log() {
  echo
  echo "==== $* ===="
}

patet_timestamp() {
  TZ=Asia/Yerevan date +"%Y-%m-%d_%H%M%S"
}

symlink_shared_files() {
  local shared_dir="$1"
  local release_dir="$2"
  shift 2
  local files=("$@")
  local f

  for f in "${files[@]}"; do
    if [[ ! -e "$shared_dir/$f" ]]; then
      echo "Missing shared file: $shared_dir/$f"
      exit 1
    fi
    ln -sfn "$shared_dir/$f" "$release_dir/$f"
  done
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

# patet_read_commit_sha_for_release <release_dir>
# Uses .patet-upload-sha (Windows artifact deploy) or git HEAD.
patet_read_commit_sha_for_release() {
  local release_dir="$1"
  local val sha

  if [[ -f "$release_dir/.patet-upload-sha" ]]; then
    IFS= read -r val <"$release_dir/.patet-upload-sha" || true
    val="${val//$'\r'/}"
    val="${val//[[:space:]]/}"
    if [[ "$val" =~ ^[a-f0-9]{7,40}$ ]]; then
      echo "$val"
      return 0
    fi
  fi

  if [[ -d "$release_dir/.git" ]] && sha="$(git -C "$release_dir" rev-parse HEAD 2>/dev/null)"; then
    echo "$sha"
    return 0
  fi

  return 1
}

verify_backend_health() {
  patet_log "Verifying backend (will retry while HTTP is 000 or empty — app still starting)"
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

# Optional Host header for loopback health checks (commercial Next.js rejects bare 127.0.0.1).
# Auto-detected from WEB_ROOT/shared/.env when NEXT_PUBLIC_COMMERCIAL_MULTI_TENANT=true.
patet_frontend_health_curl_args() {
  local -n _out=$1
  _out=()
  local env_file="${WEB_ROOT}/shared/.env"
  if [[ -f "$env_file" ]]; then
    local commercial domain
    commercial="$(grep -E '^NEXT_PUBLIC_COMMERCIAL_MULTI_TENANT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d $'\r\"' | tr '[:upper:]' '[:lower:]' | xargs)"
    domain="$(grep -E '^NEXT_PUBLIC_COMMERCIAL_PLATFORM_DOMAIN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d $'\r\"' | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "$commercial" == "true" && -n "$domain" ]]; then
      _out+=(-H "Host: ${domain}")
      return 0
    fi
  fi
  if [[ -n "${FRONTEND_HEALTH_HOST:-}" ]]; then
    _out+=(-H "Host: ${FRONTEND_HEALTH_HOST}")
  fi
}

verify_frontend_health() {
  patet_log "Verifying frontend"
  local curl_extra=()
  patet_frontend_health_curl_args curl_extra
  local curl_hint="curl -fsS"
  if ((${#curl_extra[@]} > 0)); then
    curl_hint+=" ${curl_extra[*]}"
  fi
  curl_hint+=" \"$FRONTEND_HEALTH_URL\""
  echo "Manual check (same as this script): $curl_hint"
  if ! curl -fsS "${curl_extra[@]}" "$FRONTEND_HEALTH_URL" >/dev/null; then
    echo "Frontend verification failed."
    echo "Retry manually: curl -fsS \"$FRONTEND_HEALTH_URL\""
    echo "With response headers: curl -fsSI \"$FRONTEND_HEALTH_URL\""
    exit 1
  fi
  echo "Frontend looks up."
}

run_backend_migrations() {
  patet_log "Running backend migrations"
  if [[ ! -L "$API_ROOT/current" ]]; then
    echo "Backend current symlink does not exist."
    exit 1
  fi
  cd "$API_ROOT/current"
  yarn migration:run
  echo "Backend migrations completed."
}

assert_backend_build_artifacts() {
  local release_dir="$1"
  if [[ ! -f "$release_dir/dist/src/main.js" ]]; then
    echo "ERROR: missing backend build artifact: $release_dir/dist/src/main.js"
    echo "Build on Windows (yarn build) or run deploy.sh backend to build on the server."
    exit 1
  fi
}

assert_frontend_build_artifacts() {
  local release_dir="$1"
  if [[ ! -f "$release_dir/.next/BUILD_ID" ]]; then
    echo "ERROR: next build did not produce a production output (missing $release_dir/.next/BUILD_ID)."
    echo "Typical causes: incomplete Windows upload, Linux OOM (check dmesg), disk full, or Node killed before finalize."
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
}

ensure_backend_shared_env() {
  if [[ ! -f "$API_ROOT/shared/.env" ]]; then
    echo "Missing backend shared env: $API_ROOT/shared/.env"
    exit 1
  fi
}

ensure_frontend_shared_env() {
  if [[ ! -f "$WEB_ROOT/shared/.env" ]]; then
    echo "Missing frontend shared env: $WEB_ROOT/shared/.env"
    exit 1
  fi
}

yarn_install_backend_release() {
  local release_dir="$1"
  cd "$release_dir"
  yarn install
}

yarn_install_frontend_release() {
  local release_dir="$1"
  cd "$release_dir"
  remove_non_yarn_lockfiles "$release_dir"
  yarn install --non-interactive
}

# patet_prepare_uploaded_backend <release_name>
# Symlinks shared files and runs yarn install only. Does NOT activate (no PM2/symlink/migrate).
patet_prepare_uploaded_backend() {
  local release_name="$1"
  local release_dir="$API_ROOT/releases/$release_name"

  require_cmd yarn

  if [[ ! -d "$release_dir" ]]; then
    echo "Backend release directory does not exist: $release_dir"
    exit 1
  fi

  patet_log "Installing backend release $release_name"
  ensure_backend_shared_env
  symlink_shared_files "$API_ROOT/shared" "$release_dir" "${BACKEND_SHARED_FILES[@]}"
  yarn_install_backend_release "$release_dir"
}

# patet_prepare_uploaded_frontend <release_name>
# Symlinks shared files and runs yarn install only. Does NOT activate (no PM2/symlink).
patet_prepare_uploaded_frontend() {
  local release_name="$1"
  local release_dir="$WEB_ROOT/releases/$release_name"

  require_cmd yarn

  if [[ ! -d "$release_dir" ]]; then
    echo "Frontend release directory does not exist: $release_dir"
    exit 1
  fi

  patet_log "Installing frontend release $release_name"
  ensure_frontend_shared_env
  symlink_shared_files "$WEB_ROOT/shared" "$release_dir" "${FRONTEND_SHARED_FILES[@]}"
  yarn_install_frontend_release "$release_dir"
}

reload_backend_pm2() {
  if pm2 describe patet-api >/dev/null 2>&1; then
    if ! pm2 startOrReload "$PM2_ECOSYSTEM" --only patet-api --update-env; then
      echo "PM2 startOrReload failed for patet-api — recreating from ecosystem (stale cluster state)."
      pm2 delete patet-api 2>/dev/null || true
      pm2 start "$PM2_ECOSYSTEM" --only patet-api --update-env
    fi
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-api --update-env
  fi
}

reload_frontend_pm2() {
  if pm2 describe patet-website >/dev/null 2>&1; then
    pm2 startOrReload "$PM2_ECOSYSTEM" --only patet-website --update-env
  else
    pm2 start "$PM2_ECOSYSTEM" --only patet-website --update-env
  fi
}

# patet_activate_backend_release <release_dir> <with_migrate:true|false>
patet_activate_backend_release() {
  local release_dir="$1"
  local with_migrate="${2:-false}"

  assert_backend_build_artifacts "$release_dir"

  ln -sfn "$release_dir" "$API_ROOT/current"
  echo "Backend current -> $(readlink -f "$API_ROOT/current")"

  if [[ "$with_migrate" == "true" ]]; then
    run_backend_migrations
  fi

  reload_backend_pm2
  verify_backend_health
  write_patet_release_meta "$release_dir" backend
  cleanup_releases_keep_distinct_successful_sha "$API_ROOT" "$KEEP_DISTINCT_SUCCESSFUL_SHAS" backend
}

# patet_activate_frontend_release <release_dir>
patet_activate_frontend_release() {
  local release_dir="$1"

  assert_frontend_build_artifacts "$release_dir"

  ln -sfn "$release_dir" "$WEB_ROOT/current"
  echo "Frontend current -> $(readlink -f "$WEB_ROOT/current")"

  reload_frontend_pm2
  verify_frontend_health
  write_patet_release_meta "$release_dir" frontend
  cleanup_releases_keep_distinct_successful_sha "$WEB_ROOT" "$KEEP_DISTINCT_SUCCESSFUL_SHAS" frontend
}

# patet_finalize_uploaded_backend <release_name> <with_migrate:true|false>
patet_finalize_uploaded_backend() {
  local release_name="$1"
  local with_migrate="${2:-true}"
  local release_dir="$API_ROOT/releases/$release_name"
  local _old_backend_info _old_backend_dir

  require_cmd pm2
  require_cmd curl

  _old_backend_dir="$(readlink -f "$API_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_backend_info "Backend (patet-api)" "$_old_backend_dir"

  patet_prepare_uploaded_backend "$release_name"
  patet_activate_backend_release "$release_dir" "$with_migrate"

  echo "Backend finalize complete: $release_dir"
  echo
  echo "==== Changed from: Backend (patet-api) release ===="
  echo "$_old_backend_info" | grep -v '^====' || true
  echo
  echo "==== New Running: Backend (patet-api) release ===="
  _build_release_git_info_lines "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"
}

# patet_finalize_uploaded_frontend <release_name>
patet_finalize_uploaded_frontend() {
  local release_name="$1"
  local release_dir="$WEB_ROOT/releases/$release_name"
  local _old_frontend_info _old_frontend_dir

  require_cmd pm2
  require_cmd curl

  _old_frontend_dir="$(readlink -f "$WEB_ROOT/current" 2>/dev/null || true)"
  capture_release_git_info _old_frontend_info "Frontend (patet-website)" "$_old_frontend_dir"

  patet_prepare_uploaded_frontend "$release_name"
  patet_activate_frontend_release "$release_dir"

  echo "Frontend finalize complete: $release_dir"
  echo
  echo "==== Changed from: Frontend (patet-website) release ===="
  echo "$_old_frontend_info" | grep -v '^====' || true
  echo
  echo "==== New Running: Frontend (patet-website) release ===="
  _build_release_git_info_lines "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
}

# _build_release_git_info_lines <label> <repo_dir>
# Echoes the release info lines (no surrounding separators) to stdout.
_build_release_git_info_lines() {
  local label="$1"
  local repo_dir="${2:-}"

  if [[ -z "$repo_dir" || ! -e "$repo_dir" ]]; then
    echo "  (No directory path or path missing — skipping git info)"
    return 0
  fi

  local resolved
  resolved="$(readlink -f "$repo_dir" 2>/dev/null || echo "$repo_dir")"

  if [[ ! -d "$resolved/.git" ]]; then
    echo "  Directory: $resolved"
    echo "  (Not a git checkout — skipping SHA/subject)"
    return 0
  fi

  local sha short subject
  if ! sha="$(git -C "$resolved" rev-parse HEAD 2>/dev/null)"; then
    echo "  Directory: $resolved"
    echo "  (git rev-parse failed — skipping SHA/subject)"
    return 0
  fi

  short="$(git -C "$resolved" rev-parse --short HEAD 2>/dev/null || echo "?")"
  subject="$(git -C "$resolved" log -1 --format=%s 2>/dev/null || echo "?")"

  echo "  Directory: $resolved"
  echo "  Commit:    $short ($sha)"
  echo "  Subject:   $subject"
}

print_release_git_info() {
  local label="$1"
  local repo_dir="${2:-}"
  echo "==== $label release ===="
  _build_release_git_info_lines "$label" "$repo_dir"
}

stable_marker_path() {
  local root="$1"
  echo "$root/shared/.patet-stable-release"
}

set_stable_release() {
  local root="$1"
  local release_name="$2"
  local release_dir="$root/releases/$release_name"
  local marker
  local tmp

  if [[ ! -d "$release_dir" ]]; then
    echo "Stable release target does not exist: $release_dir" >&2
    return 1
  fi

  marker="$(stable_marker_path "$root")"
  mkdir -p "$(dirname "$marker")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/patet-stable-release.XXXXXX")"
  printf '%s\n' "$release_name" >"$tmp"
  mv -f "$tmp" "$marker"
}

get_stable_release_name() {
  local root="$1"
  local marker
  local val

  marker="$(stable_marker_path "$root")"
  if [[ ! -f "$marker" ]]; then
    return 1
  fi

  IFS= read -r val <"$marker" || true
  val="${val//$'\r'/}"
  if [[ -z "$val" ]]; then
    return 1
  fi

  echo "$val"
}

# capture_release_git_info <varname> <label> <repo_dir>
# Stores the full block (header + detail lines) into the named variable.
capture_release_git_info() {
  local _cri_var="$1"
  local _cri_label="$2"
  local _cri_dir="${3:-}"
  local _cri_lines
  _cri_lines="$(  
    echo "==== $_cri_label release ===="
    _build_release_git_info_lines "$_cri_label" "$_cri_dir"
  )"
  printf -v "$_cri_var" '%s' "$_cri_lines"
}

# print_patet_running_release <app_root> <human_label>
# Prints the live "current" release: timestamps, symlink target, .patet-release.meta, and git HEAD.
print_patet_running_release() {
  local root="$1"
  local label="$2"
  local current_path="$root/current"
  local resolved
  local meta
  local line
  local commit_iso
  local branch_ref
  local descr
  local stable_release=""
  local marker

  echo
  echo "==== $label — running release ===="
  echo "  Queried at (UTC):   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "  Queried at (local): $(date +"%Y-%m-%dT%H:%M:%S%z")"

  marker="$(stable_marker_path "$root")"
  if stable_release="$(get_stable_release_name "$root" 2>/dev/null)"; then
    if [[ -d "$root/releases/$stable_release" ]]; then
      echo "  Stable release:      $stable_release"
    else
      echo "  Stable release:      $stable_release (missing on disk)"
    fi
  else
    echo "  Stable release:      (not set)"
  fi
  echo "  Stable marker file:  $marker"

  if [[ ! -e "$current_path" ]]; then
    echo "  No active release: $current_path is missing"
    return 0
  fi

  resolved="$(readlink -f "$current_path" 2>/dev/null || echo "$current_path")"
  echo "  current -> $resolved"
  echo "  Release id (folder): $(basename "$resolved")"

  meta="$resolved/.patet-release.meta"
  if [[ -f "$meta" ]]; then
    echo "  Deploy record (.patet-release.meta):"
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
      [[ -z "${line:-}" ]] && continue
      echo "    $line"
    done <"$meta"
  else
    echo "  Deploy record: (no $meta — older release or deploy predates meta file)"
  fi

  echo "  Git (checkout on disk):"
  if ! command -v git >/dev/null 2>&1; then
    echo "    (git not available)"
    return 0
  fi

  _build_release_git_info_lines "$label" "$resolved" || true

  if [[ -d "$resolved/.git" ]]; then
    commit_iso="$(git -C "$resolved" log -1 --format=%cI 2>/dev/null || true)"
    branch_ref="$(git -C "$resolved" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [[ -n "$commit_iso" ]]; then
      echo "  Commit date (author, ISO): $commit_iso"
    fi
    if [[ -n "$branch_ref" ]]; then
      echo "  Branch:                    $branch_ref"
    else
      descr="$(git -C "$resolved" describe --tags --always 2>/dev/null || true)"
      if [[ -n "$descr" ]]; then
        echo "  Describe:                  $descr"
      fi
    fi
  fi
}

# Written after health verification. Key=value lines (no shell metacharacters in values).
write_patet_release_meta() {
  local release_dir="$1"
  local stack="$2"

  if [[ ! -d "$release_dir" ]]; then
    echo "write_patet_release_meta: not a directory: $release_dir" >&2
    return 1
  fi

  local sha recorded
  if ! sha="$(patet_read_commit_sha_for_release "$release_dir")"; then
    echo "write_patet_release_meta: no commit SHA in $release_dir (.patet-upload-sha or .git required)" >&2
    return 1
  fi

  recorded="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local meta_path="$release_dir/.patet-release.meta"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/patet-release-meta.XXXXXX")"

  {
    echo "PATET_META_VERSION=1"
    echo "STACK=${stack}"
    echo "COMMIT_SHA=${sha}"
    echo "RECORDED_AT=${recorded}"
    if [[ "$stack" == "frontend" ]]; then
      if [[ ! -f "$release_dir/.next/BUILD_ID" ]]; then
        echo "write_patet_release_meta: missing .next/BUILD_ID" >&2
        rm -f "$tmp"
        return 1
      fi
      # Single-line Next.js build id
      echo -n "NEXT_BUILD_ID="
      tr -d '\n\r' <"$release_dir/.next/BUILD_ID"
      echo
    elif [[ "$stack" == "backend" ]]; then
      echo "ARTIFACT=dist/src/main.js"
    else
      echo "write_patet_release_meta: unknown stack: $stack (use backend|frontend)" >&2
      rm -f "$tmp"
      return 1
    fi
  } >"$tmp"

  mv -f "$tmp" "$meta_path"
  echo "Wrote $meta_path"
}

release_read_commit_sha() {
  local release_dir="$1"
  local meta="$release_dir/.patet-release.meta"
  local line val sha

  if [[ -f "$meta" ]]; then
    line="$(grep -E '^COMMIT_SHA=' "$meta" 2>/dev/null | head -n1 || true)"
    val="${line#COMMIT_SHA=}"
    val="${val//$'\r'/}"
    if [[ "$val" =~ ^[a-f0-9]{7,40}$ ]]; then
      echo "$val"
      return 0
    fi
  fi

  if sha="$(patet_read_commit_sha_for_release "$release_dir" 2>/dev/null)"; then
    echo "$sha"
    return 0
  fi

  return 1
}

release_is_successful_for_stack() {
  local release_dir="$1"
  local stack="$2"

  case "$stack" in
    backend)
      [[ -f "$release_dir/dist/src/main.js" ]]
      ;;
    frontend)
      [[ -f "$release_dir/.next/BUILD_ID" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# Keep live current symlink target plus newest successful dir per commit for the first N
# distinct SHAs (newest-first SHA order). Also always keep the stable-marked release dir
# (shared/.patet-stable-release) if it exists, even when it would fall outside the top N.
# Requires Bash 4+ for associative arrays.
cleanup_releases_keep_distinct_successful_sha() {
  local root="$1"
  local keep_distinct="${2:-5}"
  local stack="$3"
  local releases_dir="$root/releases"
  local current_real="" sorted dir real sha idx base all_bases stable_name stable_dir stable_real

  if [[ ! -d "$releases_dir" ]]; then
    return 0
  fi

  current_real=""
  if [[ -L "$root/current" || -e "$root/current" ]]; then
    current_real="$(readlink -f "$root/current" 2>/dev/null || true)"
  fi

  declare -A keeper_for_sha
  declare -a sha_order_newest_first=()

  mapfile -t sorted < <(ls -1dt "$releases_dir"/* 2>/dev/null || true)

  for dir in "${sorted[@]}"; do
    [[ -d "$dir" ]] || continue
    if ! release_is_successful_for_stack "$dir" "$stack"; then
      continue
    fi
    if ! sha="$(release_read_commit_sha "$dir")"; then
      continue
    fi
    [[ -n "$sha" ]] || continue
    if [[ -z "${keeper_for_sha[$sha]:-}" ]]; then
      keeper_for_sha["$sha"]="$dir"
      sha_order_newest_first+=("$sha")
    fi
  done

  declare -A keep_paths
  if [[ -n "$current_real" && -d "$current_real" ]]; then
    keep_paths["$current_real"]=1
  fi

  idx=0
  for sha in "${sha_order_newest_first[@]}"; do
    idx=$((idx + 1))
    if [[ "$idx" -le "$keep_distinct" ]]; then
      dir="${keeper_for_sha[$sha]}"
      real="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
      keep_paths["$real"]=1
    fi
  done

  # Never delete the release folder named in the stable marker (rollback safety).
  if stable_name="$(get_stable_release_name "$root" 2>/dev/null)"; then
    stable_dir="$releases_dir/$stable_name"
    if [[ -d "$stable_dir" ]]; then
      stable_real="$(readlink -f "$stable_dir" 2>/dev/null || echo "$stable_dir")"
      keep_paths["$stable_real"]=1
    fi
  fi

  mapfile -t all_bases < <(ls -1 "$releases_dir" 2>/dev/null || true)
  for base in "${all_bases[@]}"; do
    dir="$releases_dir/$base"
    [[ -e "$dir" ]] || continue
    [[ -d "$dir" ]] || continue
    real="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
    if [[ -n "${keep_paths[$real]:-}" ]]; then
      continue
    fi
    echo "Removing release: $dir"
    rm -rf "$dir"
  done
}

# PM2 cluster instances in ecosystem.config.js (patet-api and patet-website).
PATET_PM2_CLUSTER_INSTANCES="${PATET_PM2_CLUSTER_INSTANCES:-2}"

# Set by prepare_pm2_for_build; restore_pm2_cluster_sizes runs on EXIT from deploy_*.
_PATET_PM2_SCALED_DOWN_FOR_BUILD=false

_pm2_app_exists() {
  local name="$1"
  pm2 describe "$name" >/dev/null 2>&1
}

_pm2_scale_app_instances() {
  local name="$1"
  local instances="$2"
  if ! _pm2_app_exists "$name"; then
    echo "[deploy] pm2 scale $name -> $instances skipped (app not in PM2)"
    return 0
  fi
  echo "[deploy] pm2 scale $name -> $instances instance(s)"
  # Never fail deploy: PM2 may print "Nothing to do" if already at that instance count.
  pm2 scale "$name" "$instances" --update-env 2>&1 || {
    echo "[deploy] pm2 scale note for $name: continuing deploy (unchanged or PM2 error ignored)"
    return 0
  }
}

# Scale patet-api and patet-website to 1 worker each before yarn build; restore after (or on EXIT).
# Disable: PATET_BUILD_SCALE_PM2_DOWN=0
prepare_pm2_for_build() {
  local flag="${PATET_BUILD_SCALE_PM2_DOWN:-1}"
  if [[ "$flag" == "0" || "$flag" == "false" ]]; then
    return 0
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    return 0
  fi
  echo
  echo "==== PM2: scale to 1 instance (API + website) for build ===="
  _pm2_scale_app_instances patet-api 1
  _pm2_scale_app_instances patet-website 1
  _PATET_PM2_SCALED_DOWN_FOR_BUILD=true
}

restore_pm2_cluster_sizes() {
  if [[ "$_PATET_PM2_SCALED_DOWN_FOR_BUILD" != "true" ]]; then
    return 0
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    return 0
  fi
  echo
  echo "==== PM2: restore cluster size (${PATET_PM2_CLUSTER_INSTANCES} instances) ===="
  _pm2_scale_app_instances patet-api "$PATET_PM2_CLUSTER_INSTANCES"
  _pm2_scale_app_instances patet-website "$PATET_PM2_CLUSTER_INSTANCES"
  _PATET_PM2_SCALED_DOWN_FOR_BUILD=false
}
