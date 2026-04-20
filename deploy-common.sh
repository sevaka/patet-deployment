#!/usr/bin/env bash
# Shared helpers for deploy.sh and rollback.sh (source this file; do not execute directly).

print_release_git_info() {
  local label="$1"
  local repo_dir="${2:-}"

  if [[ -z "$repo_dir" || ! -e "$repo_dir" ]]; then
    echo "==== $label release ===="
    echo "  (No directory path or path missing — skipping git info)"
    return 0
  fi

  local resolved
  resolved="$(readlink -f "$repo_dir" 2>/dev/null || echo "$repo_dir")"

  if [[ ! -d "$resolved/.git" ]]; then
    echo "==== $label release ===="
    echo "  Directory: $resolved"
    echo "  (Not a git checkout — skipping SHA/subject)"
    return 0
  fi

  local sha short subject
  if ! sha="$(git -C "$resolved" rev-parse HEAD 2>/dev/null)"; then
    echo "==== $label release ===="
    echo "  Directory: $resolved"
    echo "  (git rev-parse failed — skipping SHA/subject)"
    return 0
  fi

  short="$(git -C "$resolved" rev-parse --short HEAD 2>/dev/null || echo "?")"
  subject="$(git -C "$resolved" log -1 --format=%s 2>/dev/null || echo "?")"

  echo "==== $label release ===="
  echo "  Directory: $resolved"
  echo "  Commit:    $short ($sha)"
  echo "  Subject:   $subject"
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
# distinct SHAs (newest-first SHA order). Requires Bash 4+ for associative arrays.
cleanup_releases_keep_distinct_successful_sha() {
  local root="$1"
  local keep_distinct="${2:-5}"
  local stack="$3"
  local releases_dir="$root/releases"
  local current_real="" sorted dir real sha idx base all_bases

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
