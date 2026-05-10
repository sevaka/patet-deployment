#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy-common.sh
source "$SCRIPT_DIR/deploy-common.sh"

ACTION="${1:-}"
TARGET_RELEASE="${2:-}"

API_ROOT="/var/www/patet-api"
WEB_ROOT="/var/www/patet-website"
PM2_ECOSYSTEM="/var/www/patet-deployment/ecosystem.config.js"

BACKEND_HEALTH_URL="http://127.0.0.1:57303/api/v1/auth/me"
FRONTEND_HEALTH_URL="http://127.0.0.1:4993/"

BACKEND_VERIFY_MAX_ATTEMPTS="${BACKEND_VERIFY_MAX_ATTEMPTS:-40}"
BACKEND_VERIFY_SLEEP_SECS="${BACKEND_VERIFY_SLEEP_SECS:-2}"

rollback_usage() {
  echo "Patet production rollback (point current at a release, PM2 restart/reload, verify)."
  echo
  echo "Usage: $0 {backend|frontend|all|stable|status} [release_name_or_status_scope]"
  echo "  Interactive menu: $0   (TTY only — List / Set stable / Rollback, all via numbered choices)"
  echo "  Rollback: $0 backend|frontend|all [release_name]"
  echo "            If release_name is omitted in TTY mode, opens interactive selector."
  echo "  Stable:   $0 stable backend|frontend|all [release_name|current]"
  echo "  Status:   $0 status [backend|frontend|all]  — git SHA, dates, deploy meta for live release"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help and exit"
}

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  rollback_usage
  exit 0
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

# Fills array name in $2 with absolute release dir paths, newest first (directories only).
patet_mapfile_release_dirs() {
  local root="$1"
  local -n _patet_out="$2"
  local -a _raw
  local p
  _patet_out=()
  mapfile -t _raw < <(ls -1dt "$root"/releases/* 2>/dev/null || true)
  for p in "${_raw[@]}"; do
    [[ -d "$p" ]] && _patet_out+=("$p")
  done
}

# Prints release table to stdout (newest first, current / stable tags).
list_releases_table() {
  local root="$1"
  local label="$2"
  local current_real
  local current_name=""
  local stable_name=""
  local idx=1
  local release_path
  local release_name
  local marker=""
  local tags=()
  local sha
  local sha_short
  local -a releases

  patet_mapfile_release_dirs "$root" releases
  if [[ "${#releases[@]}" -eq 0 ]]; then
    echo "No releases found under $root/releases"
    return 0
  fi

  current_real="$(readlink -f "$root/current" 2>/dev/null || true)"
  if [[ -n "$current_real" ]]; then
    current_name="$(basename "$current_real")"
  fi
  stable_name="$(get_stable_release_name "$root" 2>/dev/null || true)"
  marker="$(stable_marker_path "$root")"

  echo "==== $label — releases on disk (newest first) ===="
  echo "  Stable marker: $marker"
  if [[ -n "$stable_name" ]]; then
    echo "  Marked stable: $stable_name"
  else
    echo "  Marked stable: (not set)"
  fi
  echo

  for release_path in "${releases[@]}"; do
    release_name="$(basename "$release_path")"
    sha_short="?"
    if sha="$(release_read_commit_sha "$release_path" 2>/dev/null)"; then
      sha_short="${sha:0:7}"
    fi
    tags=()
    if [[ -n "$current_name" && "$release_name" == "$current_name" ]]; then
      tags+=("current")
    fi
    if [[ -n "$stable_name" && "$release_name" == "$stable_name" ]]; then
      tags+=("stable")
    fi

    if [[ "${#tags[@]}" -gt 0 ]]; then
      echo "  [$idx] $release_name  $sha_short  (${tags[*]})"
    else
      echo "  [$idx] $release_name  $sha_short"
    fi

    idx=$((idx + 1))
  done
  echo
}

choose_release_interactive() {
  local root="$1"
  local label="$2"
  local selected=""
  local -a releases

  patet_mapfile_release_dirs "$root" releases
  if [[ "${#releases[@]}" -eq 0 ]]; then
    echo "No releases found under $root/releases" >&2
    return 1
  fi

  echo >&2
  echo "Select release for $label" >&2
  list_releases_table "$root" "$label" >&2

  echo "Enter the release number (1-${#releases[@]})." >&2
  while true; do
    read -r -p "> " selected
    selected="${selected//[$'\r\n']}"
    if [[ -z "$selected" ]]; then
      echo "Please enter a number." >&2
      continue
    fi
    if [[ "$selected" =~ ^[0-9]+$ ]]; then
      if [[ "$selected" -ge 1 && "$selected" -le "${#releases[@]}" ]]; then
        basename "${releases[$((selected - 1))]}"
        return 0
      fi
      echo "Invalid number: $selected (valid: 1-${#releases[@]})" >&2
      continue
    fi
    echo "Enter only the list number, not a release name." >&2
  done
}

# Echoes: backend | frontend | both
choose_scope_interactive() {
  echo "Select scope:" >&2
  echo "  [1] Backend (patet-api)" >&2
  echo "  [2] Frontend (patet-website)" >&2
  echo "  [3] Both (backend + frontend — two release picks)" >&2
  echo >&2
  local c=""
  while true; do
    read -r -p "Enter choice (1-3): " c
    c="${c//[$'\r\n']}"
    case "$c" in
      1)
        echo "backend"
        return 0
        ;;
      2)
        echo "frontend"
        return 0
        ;;
      3)
        echo "both"
        return 0
        ;;
      *)
        echo "Invalid choice. Enter 1, 2, or 3." >&2
        ;;
    esac
  done
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
  local label="$2"
  local pm2_name="$3"
  local mode="$4"
  local release_name="$5"

  local target
  if [[ -n "$release_name" ]]; then
    target="$root/releases/$release_name"
    if [[ ! -d "$target" ]]; then
      echo "Release not found: $target"
      exit 1
    fi
  elif [[ -t 0 ]]; then
    local selected
    selected="$(choose_release_interactive "$root" "$label")" || {
      echo "Interactive selection failed for $label"
      exit 1
    }
    target="$root/releases/$selected"
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

mark_stable() {
  local root="$1"
  local label="$2"
  local release_name="$3"
  local resolved_release="$release_name"
  local current_real

  if [[ "$release_name" == "current" || -z "$release_name" ]]; then
    current_real="$(readlink -f "$root/current" 2>/dev/null || true)"
    if [[ -z "$current_real" || ! -d "$current_real" ]]; then
      echo "Cannot mark stable for $label: current release is missing"
      exit 1
    fi
    resolved_release="$(basename "$current_real")"
  fi

  set_stable_release "$root" "$resolved_release"
  echo "Stable release for $label set to: $resolved_release"
  echo "Marker file: $(stable_marker_path "$root")"
}

interactive_list_flow() {
  local scope
  scope="$(choose_scope_interactive)" || return 1
  case "$scope" in
    backend)
      list_releases_table "$API_ROOT" "Backend (patet-api)"
      print_patet_running_release "$API_ROOT" "Backend (patet-api)"
      ;;
    frontend)
      list_releases_table "$WEB_ROOT" "Frontend (patet-website)"
      print_patet_running_release "$WEB_ROOT" "Frontend (patet-website)"
      ;;
    both)
      list_releases_table "$API_ROOT" "Backend (patet-api)"
      print_patet_running_release "$API_ROOT" "Backend (patet-api)"
      list_releases_table "$WEB_ROOT" "Frontend (patet-website)"
      print_patet_running_release "$WEB_ROOT" "Frontend (patet-website)"
      ;;
  esac
  echo
  echo "Done."
}

interactive_stable_flow() {
  local scope
  local rel_b rel_f
  scope="$(choose_scope_interactive)" || return 1
  case "$scope" in
    backend)
      rel_b="$(choose_release_interactive "$API_ROOT" "Backend (patet-api)")" || return 1
      mark_stable "$API_ROOT" "Backend (patet-api)" "$rel_b"
      ;;
    frontend)
      rel_f="$(choose_release_interactive "$WEB_ROOT" "Frontend (patet-website)")" || return 1
      mark_stable "$WEB_ROOT" "Frontend (patet-website)" "$rel_f"
      ;;
    both)
      rel_b="$(choose_release_interactive "$API_ROOT" "Backend (patet-api)")" || return 1
      rel_f="$(choose_release_interactive "$WEB_ROOT" "Frontend (patet-website)")" || return 1
      mark_stable "$API_ROOT" "Backend (patet-api)" "$rel_b"
      mark_stable "$WEB_ROOT" "Frontend (patet-website)" "$rel_f"
      ;;
  esac
  echo
  echo "Done."
}

interactive_rollback_flow() {
  local scope
  local rel_b rel_f
  scope="$(choose_scope_interactive)" || return 1
  case "$scope" in
    backend)
      log "Rolling back backend"
      rel_b="$(choose_release_interactive "$API_ROOT" "Backend (patet-api)")" || return 1
      rollback_one "$API_ROOT" "Backend (patet-api)" "patet-api" "restart" "$rel_b"
      verify_backend
      print_release_git_info "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"
      ;;
    frontend)
      log "Rolling back frontend"
      rel_f="$(choose_release_interactive "$WEB_ROOT" "Frontend (patet-website)")" || return 1
      rollback_one "$WEB_ROOT" "Frontend (patet-website)" "patet-website" "reload" "$rel_f"
      verify_frontend
      print_release_git_info "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
      ;;
    both)
      log "Rolling back backend"
      rel_b="$(choose_release_interactive "$API_ROOT" "Backend (patet-api)")" || return 1
      rollback_one "$API_ROOT" "Backend (patet-api)" "patet-api" "restart" "$rel_b"
      verify_backend
      print_release_git_info "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"

      log "Rolling back frontend"
      rel_f="$(choose_release_interactive "$WEB_ROOT" "Frontend (patet-website)")" || return 1
      rollback_one "$WEB_ROOT" "Frontend (patet-website)" "patet-website" "reload" "$rel_f"
      verify_frontend
      print_release_git_info "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
      ;;
  esac
  echo
  echo "Rollback completed."
}

rollback_interactive_main() {
  local top=""
  echo "Patet rollback — choose an action:" >&2
  echo "  [1] List releases (disk layout + current/stable flags + running release details)" >&2
  echo "  [2] Set stable marker" >&2
  echo "  [3] Rollback (switch current + PM2)" >&2
  echo >&2
  while true; do
    read -r -p "Enter choice (1-3): " top
    top="${top//[$'\r\n']}"
    case "$top" in
      1)
        interactive_list_flow
        return $?
        ;;
      2)
        interactive_stable_flow
        return $?
        ;;
      3)
        interactive_rollback_flow
        return $?
        ;;
      *)
        echo "Invalid choice. Enter 1, 2, or 3." >&2
        ;;
    esac
  done
}

if [[ -z "$ACTION" ]]; then
  if [[ -t 0 && -t 1 ]]; then
    rollback_interactive_main
    exit $?
  fi
  rollback_usage
  exit 1
fi

case "$ACTION" in
  backend)
    log "Rolling back backend"
    rollback_one "$API_ROOT" "Backend (patet-api)" "patet-api" "restart" "$TARGET_RELEASE"
    verify_backend
    print_release_git_info "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"
    ;;
  frontend)
    log "Rolling back frontend"
    rollback_one "$WEB_ROOT" "Frontend (patet-website)" "patet-website" "reload" "$TARGET_RELEASE"
    verify_frontend
    print_release_git_info "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
    ;;
  all)
    log "Rolling back backend"
    rollback_one "$API_ROOT" "Backend (patet-api)" "patet-api" "restart" "$TARGET_RELEASE"
    verify_backend
    print_release_git_info "Backend (patet-api)" "$(readlink -f "$API_ROOT/current")"

    log "Rolling back frontend"
    rollback_one "$WEB_ROOT" "Frontend (patet-website)" "patet-website" "reload" "$TARGET_RELEASE"
    verify_frontend
    print_release_git_info "Frontend (patet-website)" "$(readlink -f "$WEB_ROOT/current")"
    ;;
  stable)
    STABLE_SCOPE="${2:-}"
    STABLE_RELEASE="${3:-current}"
    case "$STABLE_SCOPE" in
      backend)
        mark_stable "$API_ROOT" "Backend (patet-api)" "$STABLE_RELEASE"
        ;;
      frontend)
        mark_stable "$WEB_ROOT" "Frontend (patet-website)" "$STABLE_RELEASE"
        ;;
      all)
        mark_stable "$API_ROOT" "Backend (patet-api)" "$STABLE_RELEASE"
        mark_stable "$WEB_ROOT" "Frontend (patet-website)" "$STABLE_RELEASE"
        ;;
      *)
        echo "Invalid stable scope: ${STABLE_SCOPE:-<empty>}"
        echo "Usage: $0 stable backend|frontend|all [release_name|current]"
        rollback_usage
        exit 1
        ;;
    esac
    echo
    echo "Done."
    exit 0
    ;;
  status)
    STATUS_SCOPE="${2:-all}"
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
        rollback_usage
        exit 1
        ;;
    esac
    echo
    echo "Done."
    exit 0
    ;;
  *)
    echo "Unknown action: $ACTION"
    rollback_usage
    exit 1
    ;;
esac

echo
echo "Rollback completed."

