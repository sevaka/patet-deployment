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
