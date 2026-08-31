#!/usr/bin/env bash
# Build patet-back-nestjs and/or patet-website locally on Linux, upload to Ubuntu VPS,
# finalize via finalize-release.sh on the server (same flow as deploy-from-windows.ps1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACK_AND_FRONT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE="patet-am"
TARGET="all"
SKIP_BUILD=false
MIGRATE=false
SKIP_UPLOAD=false
SYNC_SCRIPTS=false
FORCE_VIDEOS=false
RELEASE_ID=""
HAS_EXPLICIT_DEPLOY_OPTS=false
DEPLOY_PROFILE_LABEL=""
declare -A FRONTEND_BUILD_ENV=()

usage() {
  cat <<'EOF'
Usage: deploy-from-linux.sh [backend|frontend|all] [options]

Build locally, upload release artifacts, finalize on the VPS (OpenSSH + rsync/scp).

Options:
  --profile NAME              patet-am (default) or commercial
  --skip-build                Upload/finalize only (artifacts must exist locally)
  --skip-upload               Build only; do not upload or finalize
  --migrate                   Run backend migrations during finalize
  --sync-deployment-scripts   Upload finalize-release.sh, deploy-common.sh, etc.
  --force-sync-videos         Re-upload all demo MP4/MOV even if SHA-256 matches
  --release-id ID             Override release folder name (default: Asia/Yerevan timestamp)
  -h, --help                  Show this help

Examples:
  ./deploy-patet.sh
  ./deploy-patet.sh backend
  ./deploy-patet.sh all --migrate
  ./deploy-from-linux.sh frontend --sync-deployment-scripts
  ./deploy-patet.sh all --skip-build --release-id 2026-08-29_120000

Run with no arguments to open the same interactive menu as deploy-from-windows.ps1:

  ./deploy-patet.sh

Profile: profiles/<profile>.env (SSH host, paths, FRONTEND_BUILD_* vars).
EOF
}

log_step() {
  echo ""
  echo "==== $* ===="
}

log_sub() {
  echo "  [$(date +%H:%M:%S)] $*"
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      backend|frontend|all)
        TARGET="$1"
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --profile)
        [[ $# -ge 2 ]] || die "--profile requires a value"
        PROFILE="$2"
        shift 2
        ;;
      --skip-build)
        SKIP_BUILD=true
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --skip-upload)
        SKIP_UPLOAD=true
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --migrate)
        MIGRATE=true
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --sync-deployment-scripts)
        SYNC_SCRIPTS=true
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --force-sync-videos)
        FORCE_VIDEOS=true
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift
        ;;
      --release-id)
        [[ $# -ge 2 ]] || die "--release-id requires a value"
        RELEASE_ID="$2"
        HAS_EXPLICIT_DEPLOY_OPTS=true
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1 (use --help)"
        ;;
    esac
  done
}

resolve_profile_path() {
  local name="$1"
  local profile_file="$SCRIPT_DIR/profiles/${name}.env"
  if [[ -f "$profile_file" ]]; then
    echo "$profile_file"
    return 0
  fi
  local legacy=""
  if [[ "$name" == commercial ]]; then
    legacy="$SCRIPT_DIR/deploy.local.commercial.env"
  else
    legacy="$SCRIPT_DIR/deploy.local.env"
  fi
  if [[ -f "$legacy" ]]; then
    echo "$legacy"
    return 0
  fi
  die "Missing deploy profile. Copy profiles/${name}.env.example to profiles/${name}.env and set PATET_SSH_HOST / PATET_SSH_USER."
}

load_deploy_profile() {
  local path
  path="$(resolve_profile_path "$PROFILE")"
  local line name value env_key
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    name="${line%%=*}"
    name="${name%"${name##*[![:space:]]}"}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%%#*}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:${#value}-2}"
    fi
    if [[ "$name" == FRONTEND_BUILD_* ]]; then
      env_key="${name#FRONTEND_BUILD_}"
      FRONTEND_BUILD_ENV["$env_key"]="$value"
    elif [[ "$name" == PATET_PROFILE_LABEL ]]; then
      DEPLOY_PROFILE_LABEL="$value"
    else
      export "$name=$value"
    fi
  done < "$path"
  [[ -n "${DEPLOY_PROFILE_LABEL:-}" ]] || DEPLOY_PROFILE_LABEL="$PROFILE"
}

resolve_repo_path() {
  local rel="${1:-}"
  if [[ "$rel" == /* ]]; then
    echo "$rel"
  else
    echo "$BACK_AND_FRONT_ROOT/$rel"
  fi
}

get_release_timestamp() {
  if [[ -n "$RELEASE_ID" ]]; then
    echo "$RELEASE_ID"
    return
  fi
  TZ=Asia/Yerevan date +%Y-%m-%d_%H%M%S
}

# Port flag: ssh uses -p; scp uses -P ( -p means "preserve times" for scp ).
ssh_extra_args() {
  local port_flag="${1:--p}"
  local -a args=()
  if [[ -n "${PATET_SSH_PORT:-}" ]]; then
    args+=("$port_flag" "$PATET_SSH_PORT")
  fi
  if [[ -n "${PATET_SSH_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=($PATET_SSH_EXTRA_ARGS)
    args+=("${extra[@]}")
  fi
  if [[ ${#args[@]} -eq 0 ]]; then
    return
  fi
  echo "${args[@]}"
}

verify_ssh_connectivity() {
  local ssh_target="${PATET_SSH_USER}@${PATET_SSH_HOST}"
  local port="${PATET_SSH_PORT:-22}"
  log_step "Checking SSH to $ssh_target (port $port)"
  if timeout 10 ssh -n $(ssh_extra_args) -o ConnectTimeout=5 -o BatchMode=yes \
    "$ssh_target" "echo ok" >/dev/null 2>&1; then
    log_sub "SSH OK"
    return 0
  fi
  local probe=""
  probe="$(curl -s --max-time 5 http://example.com 2>/dev/null || true)"
  if echo "$probe" | grep -qiE 'hotspot|captive|login required'; then
    if [[ "$port" == "22" ]] && timeout 3 bash -c "echo >/dev/tcp/${PATET_SSH_HOST}/2222" 2>/dev/null; then
      die "Cannot SSH on port 22 (WiFi hotspot). Port 2222 is reachable — set PATET_SSH_PORT=2222 in profiles/$PROFILE.env and retry."
    fi
    die "Cannot SSH to $ssh_target:port $port — this WiFi hotspot blocks outbound SSH. Complete hotspot login in a browser, or switch to mobile hotspot/VPN, then retry. If the build already finished, resume with: ./deploy-patet.sh <target> --skip-build --release-id <id>"
  fi
  if ! timeout 3 bash -c "echo >/dev/tcp/${PATET_SSH_HOST}/${port}" 2>/dev/null; then
    die "Cannot reach SSH on ${PATET_SSH_HOST}:$port from this network (connection refused). Use mobile hotspot/VPN, or set PATET_SSH_PORT in profiles/$PROFILE.env if the server listens on another port."
  fi
  die "SSH to $ssh_target failed (port $port reachable but auth rejected). Check PATET_SSH_EXTRA_ARGS / key in profiles/$PROFILE.env."
}

invoke_ssh() {
  local remote_cmd="$1"
  local ssh_target="${PATET_SSH_USER}@${PATET_SSH_HOST}"
  # shellcheck disable=SC2046
  ssh -n $(ssh_extra_args) "$ssh_target" "$remote_cmd"
}

invoke_scp() {
  local local_path="$1"
  local remote_spec="$2"
  # shellcheck disable=SC2046
  scp $(ssh_extra_args -P) "$local_path" "$remote_spec"
}

rsync_rsh() {
  local extra
  extra="$(ssh_extra_args)"
  if [[ -z "$extra" ]]; then
    echo "ssh -n"
  else
    echo "ssh -n $extra"
  fi
}

upload_exclude_rsync() {
  # Use --exclude=VALUE (one argv). "echo --exclude pat" becomes a single
  # "--exclude pat" token when read into an array, which rsync 3.1.x rejects.
  local names=(
    node_modules .git .next/cache .next/trace .env .env.*
    coverage .cursor .turbo .vscode
  )
  local pat
  for pat in "${names[@]}"; do
    echo "--exclude=$pat"
    echo "--exclude=$pat/"
  done
  echo '--exclude=*.mp4'
  echo '--exclude=*.MP4'
  echo '--exclude=*.mov'
  echo '--exclude=*.MOV'
  echo '--exclude=*.log'
}

upload_exclude_tar() {
  local names=(
    node_modules .git .next/cache .next/trace .env .env.*
    coverage .cursor .turbo .vscode
    '*.mp4' '*.MP4' '*.mov' '*.MOV'
  )
  local name
  for name in "${names[@]}"; do
    echo --exclude="$name"
  done
}

apply_frontend_build_profile() {
  local repo_path="$1"
  if [[ ${#FRONTEND_BUILD_ENV[@]} -eq 0 ]]; then
    echo "Warning: No FRONTEND_BUILD_* vars in deploy profile; frontend build uses local .env only." >&2
    return 0
  fi
  local out_path="$repo_path/.env.production.local"
  {
    echo "# Auto-generated by deploy-from-linux.sh — do not commit"
    echo "# Profile: $PROFILE ($DEPLOY_PROFILE_LABEL)"
    local key
    for key in $(printf '%s\n' "${!FRONTEND_BUILD_ENV[@]}" | sort); do
      echo "${key}=${FRONTEND_BUILD_ENV[$key]}"
    done
  } >"$out_path"
  log_sub "Wrote $out_path from deploy profile (${#FRONTEND_BUILD_ENV[@]} vars)"
}

remove_frontend_build_profile() {
  local repo_path="$1"
  local out_path="$repo_path/.env.production.local"
  if [[ -f "$out_path" ]]; then
    rm -f "$out_path"
    log_sub "Removed $out_path"
  fi
}

write_upload_sha() {
  local repo_path="$1"
  require_cmd git
  local sha
  sha="$(git -C "$repo_path" rev-parse HEAD)"
  if [[ ! "$sha" =~ ^[a-f0-9]{7,40}$ ]]; then
    die "git rev-parse HEAD returned unexpected value in $repo_path"
  fi
  printf '%s' "$sha" >"$repo_path/.patet-upload-sha"
  echo "Wrote .patet-upload-sha ($sha)"
}

yarn_build() {
  local repo_path="$1"
  local kind="$2"
  log_step "Building $kind in $repo_path"
  local frontend_profile_applied=false
  pushd "$repo_path" >/dev/null
  unset NODE_ENV || true
  if [[ "$kind" == frontend ]]; then
    apply_frontend_build_profile "$repo_path"
    frontend_profile_applied=true
    rm -f package-lock.json npm-shrinkwrap.json
    for stale in .next/trace .next/cache; do
      if [[ -e "$stale" ]]; then
        log_sub "Removing stale $stale before build..."
        rm -rf "$stale" || die "Cannot access $stale (stop 'next dev' and retry)"
      fi
    done
  fi
  yarn install
  if [[ "$kind" == frontend ]]; then
    export NODE_ENV=production
    rm -rf .next
  fi
  yarn build
  unset NODE_ENV || true
  if [[ "$kind" == backend ]]; then
    [[ -f dist/src/main.js ]] || die "Backend build missing dist/src/main.js"
  else
    [[ -f .next/BUILD_ID ]] || die "Frontend build missing .next/BUILD_ID"
  fi
  write_upload_sha "$repo_path"
  if [[ "$frontend_profile_applied" == true ]]; then
    remove_frontend_build_profile "$repo_path"
  fi
  popd >/dev/null
}

upload_via_rsync() {
  local local_path="$1"
  local remote_path="$2"
  local ssh_target="$3"
  require_cmd rsync
  local -a excludes=()
  local item
  while IFS= read -r item; do
    excludes+=("$item")
  done < <(upload_exclude_rsync)
  local local_trail="${local_path%/}/"
  local rsh
  rsh="$(rsync_rsh)"
  # RSYNC_RSH avoids old rsync builds misparsing `-e ssh -n -i …` as separate flags.
  # shellcheck disable=SC2086
  if RSYNC_RSH="$rsh" rsync -avz --delete "${excludes[@]}" "$local_trail" "${ssh_target}:${remote_path}/"; then
    return 0
  fi
  echo "Warning: rsync failed; falling back to tar+scp." >&2
  return 1
}

upload_via_tar_scp() {
  local local_path="$1"
  local remote_path="$2"
  local ssh_target="$3"
  log_step "Uploading via tar+scp (rsync not available or failed)"
  require_cmd tar
  require_cmd scp
  require_cmd ssh
  local archive
  archive="$(mktemp /tmp/patet-release-XXXXXX.tgz)"
  local -a tar_excludes=()
  local item
  while IFS= read -r item; do
    tar_excludes+=("$item")
  done < <(upload_exclude_tar)
  log_sub "Creating compressed archive (excludes node_modules, .git, .next/cache, .next/trace, *.mp4)..."
  local start=$SECONDS
  tar -czf "$archive" "${tar_excludes[@]}" -C "$local_path" .
  local size_mb
  size_mb="$(du -m "$archive" | cut -f1)"
  log_sub "Archive ready: ${size_mb} MB in $((SECONDS - start))s"
  local remote_parent="${remote_path%/*}"
  log_sub "Ensuring remote release directory exists..."
  invoke_ssh "mkdir -p '$remote_parent' '$remote_path'"
  log_sub "Uploading ${size_mb} MB to server (scp)..."
  start=$SECONDS
  invoke_scp "$archive" "${ssh_target}:/tmp/patet-release.tgz"
  log_sub "Upload finished in $((SECONDS - start))s"
  log_sub "Extracting on server..."
  start=$SECONDS
  invoke_ssh "rm -rf '$remote_path' && mkdir -p '$remote_path' && tar -xzf /tmp/patet-release.tgz -C '$remote_path' && rm -f /tmp/patet-release.tgz"
  log_sub "Extract finished in $((SECONDS - start))s"
  rm -f "$archive"
}

upload_release() {
  local local_path="$1"
  local remote_path="$2"
  local ssh_target="$3"
  log_step "Upload $local_path -> $remote_path"
  if ! upload_via_rsync "$local_path" "$remote_path" "$ssh_target"; then
    upload_via_tar_scp "$local_path" "$remote_path" "$ssh_target"
  fi
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

get_remote_video_hashes() {
  local ssh_target="$1"
  local remote_dir="$2"
  local remote_cmd
  remote_cmd="mkdir -p '$remote_dir'; cd '$remote_dir'; find . -maxdepth 1 -type f \\( -iname '*.mp4' -o -iname '*.mov' \\) -exec sha256sum {} +"
  invoke_ssh "$remote_cmd" 2>/dev/null || true
}

sync_frontend_shared_videos() {
  local repo_path="$1"
  local web_root="$2"
  local ssh_target="$3"
  local force="$4"
  local video_dir="$repo_path/public/assets/videos"
  local remote_dir="$web_root/shared/assets-videos"
  log_step "Sync demo videos -> $remote_dir"
  if [[ ! -d "$video_dir" ]]; then
    echo "Warning: No public/assets/videos directory. Skipping video sync." >&2
    return 0
  fi
  mapfile -t local_files < <(find "$video_dir" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' \) -printf '%f\n' 2>/dev/null | sort)
  if [[ ${#local_files[@]} -eq 0 ]]; then
    echo "Warning: No local MP4/MOV files under public/assets/videos. Skipping video sync." >&2
    return 0
  fi
  declare -A remote_hashes=()
  local line hash name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([a-fA-F0-9]{64})[[:space:]]+(.+)$ ]]; then
      hash="${BASH_REMATCH[1],,}"
      name="$(basename "${BASH_REMATCH[2]// /}")"
      remote_hashes["$name"]="$hash"
    fi
  done < <(get_remote_video_hashes "$ssh_target" "$remote_dir")
  local -a to_upload=()
  local file local_hash remote_hash
  for file in "${local_files[@]}"; do
    local_hash="$(sha256_file "$video_dir/$file")"
    remote_hash="${remote_hashes[$file]:-}"
    if [[ "$force" != true && -n "$remote_hash" && "$remote_hash" == "$local_hash" ]]; then
      log_sub "Skip unchanged $file"
      continue
    fi
    to_upload+=("$file")
  done
  if [[ ${#to_upload[@]} -eq 0 ]]; then
    log_sub "All ${#local_files[@]} demo videos already on server (hash match)."
    return 0
  fi
  local total_bytes=0
  for file in "${to_upload[@]}"; do
    total_bytes=$((total_bytes + $(stat -c%s "$video_dir/$file")))
  done
  local size_mb=$(( (total_bytes + 524287) / 1048576 ))
  log_sub "Uploading ${#to_upload[@]} video(s), ${size_mb} MB (new or changed)..."
  local staging archive
  staging="$(mktemp -d /tmp/patet-videos-XXXXXX)"
  archive="$(mktemp /tmp/patet-shared-videos-XXXXXX.tgz)"
  for file in "${to_upload[@]}"; do
    cp "$video_dir/$file" "$staging/$file"
  done
  tar -czf "$archive" -C "$staging" .
  invoke_scp "$archive" "${ssh_target}:/tmp/patet-shared-videos.tgz"
  invoke_ssh "mkdir -p '$remote_dir' && tar -xzf /tmp/patet-shared-videos.tgz -C '$remote_dir' && rm -f /tmp/patet-shared-videos.tgz"
  log_sub "Shared demo videos updated."
  rm -rf "$staging" "$archive"
}

ensure_frontend_videos_link() {
  local web_root="$1"
  local ssh_target="$2"
  local remote_dir="$web_root/shared/assets-videos"
  local link_path="$web_root/current/public/assets/videos"
  local parent_path="$web_root/current/public/assets"
  log_step "Link $link_path -> $remote_dir"
  invoke_ssh "mkdir -p '$parent_path' '$remote_dir'; rm -rf '$link_path'; ln -sfn '$remote_dir' '$link_path'; readlink '$link_path'"
}

sync_deployment_scripts() {
  local ssh_target="$1"
  local dest="${PATET_DEPLOYMENT_ROOT:-/var/www/patet-deployment}"
  local files=(
    deploy-config.sh
    deploy-common.sh
    finalize-release.sh
    ecosystem.config.js
  )
  local f local
  for f in "${files[@]}"; do
    local="$SCRIPT_DIR/$f"
    [[ -f "$local" ]] || continue
    echo "Uploading deployment script $f"
    invoke_scp "$local" "${ssh_target}:${dest}/$f"
  done
  invoke_ssh "perl -pi -e 's/\r\n|\r/\n/g' '$dest'/*.sh 2>/dev/null || true; chmod +x '$dest/finalize-release.sh' '$dest/deploy.sh' '$dest/rollback.sh' 2>/dev/null || true"
}

wrapper_script_name() {
  if [[ "$PROFILE" == commercial ]]; then
    echo "deploy-commercial.sh"
  else
    echo "deploy-patet.sh"
  fi
}

print_manual_command() {
  local wrapper
  wrapper="$(wrapper_script_name)"
  echo ""
  echo "Copy for next time (non-interactive):"
  echo "  cd \"$SCRIPT_DIR\""
  local cmd="./$wrapper"
  [[ "$TARGET" != all ]] && cmd+=" $TARGET"
  [[ "$MIGRATE" == true ]] && cmd+=" --migrate"
  [[ "$SYNC_SCRIPTS" == true ]] && cmd+=" --sync-deployment-scripts"
  [[ "$FORCE_VIDEOS" == true ]] && cmd+=" --force-sync-videos"
  [[ "$SKIP_BUILD" == true ]] && cmd+=" --skip-build"
  [[ "$SKIP_UPLOAD" == true ]] && cmd+=" --skip-upload"
  [[ -n "$RELEASE_ID" ]] && cmd+=" --release-id \"$RELEASE_ID\""
  echo "  $cmd"
}

print_deploy_summary() {
  local summary_line="$1"
  echo ""
  echo "Starting deploy:"
  echo "  $summary_line"
  print_manual_command
}

# Prints menu to stderr; selected option number (1-based) to stdout.
read_number_choice() {
  local title="$1"
  local default_index="$2"
  shift 2
  local -a options=("$@")
  local max=${#options[@]}
  local i n raw pick

  echo "" >&2
  echo "$title" >&2
  for ((i = 0; i < max; i++)); do
    n=$((i + 1))
    if [[ $n -eq $default_index ]]; then
      echo "  [$n] ${options[$i]} (default)" >&2
    else
      echo "  [$n] ${options[$i]}" >&2
    fi
  done

  while true; do
    read -r -p "Enter choice (1-$max, Enter=$default_index): " raw
    if [[ -z "$raw" ]]; then
      echo "$default_index"
      return 0
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      pick=$raw
      if [[ $pick -ge 1 && $pick -le $max ]]; then
        echo "$pick"
        return 0
      fi
    fi
    echo "Invalid choice. Enter a number from 1 to $max." >&2
  done
}

deploy_interactive_quick() {
  local deploy_target="$1"
  local with_migrate="$2"
  TARGET="$deploy_target"
  MIGRATE="$with_migrate"
  SYNC_SCRIPTS=false
  FORCE_VIDEOS=false
  SKIP_BUILD=false
  SKIP_UPLOAD=false

  local target_label migrate_label
  case "$deploy_target" in
    backend) target_label="backend only" ;;
    frontend) target_label="frontend only" ;;
    *) target_label="backend + frontend" ;;
  esac
  if [[ "$deploy_target" == frontend ]]; then
    migrate_label="n/a"
  elif [[ "$with_migrate" == true ]]; then
    migrate_label="yes"
  else
    migrate_label="no"
  fi
  print_deploy_summary "Quick: $target_label, full build + upload + finalize, migrations=$migrate_label, no script sync"
}

deploy_interactive_detailed() {
  local pick includes_backend includes_frontend migrate_summary mode_summary video_summary summary

  pick="$(read_number_choice "What to deploy?" 3 \
    "Backend only (patet-api)" \
    "Frontend only (patet-website)" \
    "Both (backend + frontend)")"
  case "$pick" in
    1) TARGET="backend" ;;
    2) TARGET="frontend" ;;
    *) TARGET="all" ;;
  esac

  includes_backend=false
  includes_frontend=false
  [[ "$TARGET" == backend || "$TARGET" == all ]] && includes_backend=true
  [[ "$TARGET" == frontend || "$TARGET" == all ]] && includes_frontend=true

  if [[ "$includes_backend" == true ]]; then
    pick="$(read_number_choice "Run backend migrations during finalize?" 1 \
      "No - skip migrations" \
      "Yes - run yarn migration:run on server")"
    MIGRATE=false
    [[ "$pick" -eq 2 ]] && MIGRATE=true
  else
    MIGRATE=false
  fi

  pick="$(read_number_choice "Sync deployment scripts to server before finalize?" 1 \
    "No" \
    "Yes (finalize-release.sh, deploy-common.sh, etc.)")"
  SYNC_SCRIPTS=false
  [[ "$pick" -eq 2 ]] && SYNC_SCRIPTS=true

  if [[ "$includes_frontend" == true ]]; then
    pick="$(read_number_choice "Re-upload all demo MP4s to the shared store (even if unchanged)?" 1 \
      "No - skip files whose SHA-256 already matches the server" \
      "Yes - copy every local public/assets/videos file again")"
    FORCE_VIDEOS=false
    [[ "$pick" -eq 2 ]] && FORCE_VIDEOS=true
  else
    FORCE_VIDEOS=false
  fi

  pick="$(read_number_choice "Deploy mode?" 1 \
    "Full - build locally, upload, finalize on server" \
    "Build only - no upload or finalize" \
    "Upload + finalize only - skip local build (artifacts must exist)")"
  case "$pick" in
    2)
      SKIP_BUILD=false
      SKIP_UPLOAD=true
      ;;
    3)
      SKIP_BUILD=true
      SKIP_UPLOAD=false
      ;;
    *)
      SKIP_BUILD=false
      SKIP_UPLOAD=false
      ;;
  esac

  if [[ "$SKIP_BUILD" == true && -z "$RELEASE_ID" ]]; then
    pick="$(read_number_choice "Reuse an existing release folder on the server?" 1 \
      "No - generate a new release id (timestamp)" \
      "Yes - enter an existing release id")"
    if [[ "$pick" -eq 2 ]]; then
      read -r -p "Release id (e.g. 2026-05-22_161454): " RELEASE_ID
      RELEASE_ID="${RELEASE_ID#"${RELEASE_ID%%[![:space:]]*}"}"
      RELEASE_ID="${RELEASE_ID%"${RELEASE_ID##*[![:space:]]}"}"
      [[ -n "$RELEASE_ID" ]] || die "Release id is required when skipping build without a new timestamp."
    fi
  fi

  if [[ "$includes_backend" == true ]]; then
    migrate_summary=$([[ "$MIGRATE" == true ]] && echo yes || echo no)
  else
    migrate_summary="n/a"
  fi
  if [[ "$SKIP_UPLOAD" == true ]]; then
    mode_summary="build only"
  elif [[ "$SKIP_BUILD" == true ]]; then
    mode_summary="upload + finalize"
  else
    mode_summary="full"
  fi
  if [[ "$includes_frontend" == true ]]; then
    video_summary=$([[ "$FORCE_VIDEOS" == true ]] && echo force || echo hash-skip)
  else
    video_summary="n/a"
  fi
  summary="Target=$TARGET, migrations=$migrate_summary, sync scripts=$([[ "$SYNC_SCRIPTS" == true ]] && echo yes || echo no), videos=$video_summary, mode=$mode_summary"
  [[ -n "$RELEASE_ID" ]] && summary+=", release id=$RELEASE_ID"
  print_deploy_summary "$summary"
}

deploy_interactive_prompts() {
  local profile_hint="" entry_pick
  [[ -n "$DEPLOY_PROFILE_LABEL" ]] && profile_hint=" - $DEPLOY_PROFILE_LABEL"
  echo ""
  echo "Patet Linux deploy$profile_hint"

  entry_pick="$(read_number_choice "What do you want to do?" 3 \
    "Backend only" \
    "Frontend only" \
    "Backend + frontend" \
    "Backend + frontend + migrations" \
    "More options (sync scripts, deploy mode, release id, etc.)")"

  case "$entry_pick" in
    1) deploy_interactive_quick backend false ;;
    2) deploy_interactive_quick frontend false ;;
    3) deploy_interactive_quick all false ;;
    4) deploy_interactive_quick all true ;;
    *) deploy_interactive_detailed ;;
  esac
}

main() {
  parse_args "$@"
  load_deploy_profile

  [[ -n "${PATET_SSH_HOST:-}" && -n "${PATET_SSH_USER:-}" ]] \
    || die "PATET_SSH_HOST and PATET_SSH_USER must be set in profiles/$PROFILE.env"

  if [[ "$HAS_EXPLICIT_DEPLOY_OPTS" != true ]]; then
    deploy_interactive_prompts
  fi

  local api_root="${PATET_API_ROOT:-/var/www/patet-api}"
  local web_root="${PATET_WEB_ROOT:-/var/www/patet-website}"
  local deploy_root="${PATET_DEPLOYMENT_ROOT:-/var/www/patet-deployment}"
  local backend_local
  local frontend_local
  backend_local="$(resolve_repo_path "${PATET_LOCAL_BACKEND:-patet-back-nestjs}")"
  frontend_local="$(resolve_repo_path "${PATET_LOCAL_FRONTEND:-patet-website}")"
  local release
  release="$(get_release_timestamp)"
  local ssh_target="${PATET_SSH_USER}@${PATET_SSH_HOST}"

  echo ""
  echo "Deploy profile: $DEPLOY_PROFILE_LABEL"
  echo "SSH target:     $ssh_target"
  if [[ ${#FRONTEND_BUILD_ENV[@]} -gt 0 ]]; then
    echo "Frontend build: ${#FRONTEND_BUILD_ENV[@]} vars from profile (FRONTEND_BUILD_*)"
  fi

  log_step "Patet Linux deploy - profile=$PROFILE target=$TARGET release=$release"
  if [[ "$HAS_EXPLICIT_DEPLOY_OPTS" == true ]]; then
    print_manual_command
  fi

  local do_backend=false do_frontend=false
  [[ "$TARGET" == backend || "$TARGET" == all ]] && do_backend=true
  [[ "$TARGET" == frontend || "$TARGET" == all ]] && do_frontend=true

  if [[ "$SKIP_BUILD" != true ]]; then
    $do_backend && yarn_build "$backend_local" backend
    $do_frontend && yarn_build "$frontend_local" frontend
  fi

  if [[ "$SKIP_UPLOAD" == true ]]; then
    echo "SkipUpload set - done after build."
    exit 0
  fi

  require_cmd ssh
  require_cmd scp
  verify_ssh_connectivity

  if [[ "$SYNC_SCRIPTS" == true ]]; then
    sync_deployment_scripts "$ssh_target"
  fi

  if $do_backend; then
    upload_release "$backend_local" "$api_root/releases/$release" "$ssh_target"
  fi

  if $do_frontend; then
    upload_release "$frontend_local" "$web_root/releases/$release" "$ssh_target"
    sync_frontend_shared_videos "$frontend_local" "$web_root" "$ssh_target" "$FORCE_VIDEOS"
  fi

  local finalize_cmd="cd '$deploy_root' && bash ./finalize-release.sh $TARGET $release"
  [[ "$MIGRATE" == true ]] && finalize_cmd+=" --with-migrate"
  log_step "Finalizing on server"
  invoke_ssh "$finalize_cmd"

  if $do_frontend; then
    ensure_frontend_videos_link "$web_root" "$ssh_target"
  fi

  log_step "Deploy finished"
  echo "Release id: $release"
  echo "Check status on server: ssh $ssh_target \"cd $deploy_root && ./deploy.sh status all\""
}

main "$@"
