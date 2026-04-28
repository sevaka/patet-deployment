#!/usr/bin/env bash
# Shared helpers for deploy.sh and rollback.sh (source this file; do not execute directly).

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
  if ! sha="$(git -C "$release_dir" rev-parse HEAD 2>/dev/null)"; then
    echo "write_patet_release_meta: git rev-parse failed in $release_dir" >&2
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

  if [[ -d "$release_dir/.git" ]] && sha="$(git -C "$release_dir" rev-parse HEAD 2>/dev/null)"; then
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
