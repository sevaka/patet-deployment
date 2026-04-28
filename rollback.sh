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

if [[ -z "$ACTION" ]]; then
  rollback_usage
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

choose_release_interactive() {
  local root="$1"
  local label="$2"
  local current_real
  local current_name=""
  local stable_name=""
  local idx=1
  local selected=""
  local release_path
  local release_name
  local marker=""
  local tags=()

  mapfile -t releases < <(ls -1dt "$root"/releases/* 2>/dev/null || true)
  if [[ "${#releases[@]}" -eq 0 ]]; then
    echo "No releases found under $root/releases" >&2
    return 1
  fi

  current_real="$(readlink -f "$root/current" 2>/dev/null || true)"
  if [[ -n "$current_real" ]]; then
    current_name="$(basename "$current_real")"
  fi
  stable_name="$(get_stable_release_name "$root" 2>/dev/null || true)"
  marker="$(stable_marker_path "$root")"

  echo >&2
  echo "Select rollback target for $label" >&2
  echo "  Stable marker: $marker" >&2
  if [[ -n "$stable_name" ]]; then
    echo "  Stable release: $stable_name" >&2
  else
    echo "  Stable release: (not set)" >&2
  fi
  echo >&2

  for release_path in "${releases[@]}"; do
    [[ -d "$release_path" ]] || continue
    release_name="$(basename "$release_path")"
    tags=()
    if [[ -n "$current_name" && "$release_name" == "$current_name" ]]; then
      tags+=("current")
    fi
    if [[ -n "$stable_name" && "$release_name" == "$stable_name" ]]; then
      tags+=("stable")
    fi

    if [[ "${#tags[@]}" -gt 0 ]]; then
      echo "  [$idx] $release_name (${tags[*]})" >&2
    else
      echo "  [$idx] $release_name" >&2
    fi

    idx=$((idx + 1))
  done

  echo >&2
  echo "Enter release number or exact release name." >&2
  while true; do
    read -r -p "> " selected
    selected="${selected//[$'\r\n']}"
    if [[ -z "$selected" ]]; then
      echo "Please select a release." >&2
      continue
    fi
    if [[ "$selected" =~ ^[0-9]+$ ]]; then
      if [[ "$selected" -ge 1 && "$selected" -le "${#releases[@]}" ]]; then
        basename "${releases[$((selected - 1))]}"
        return 0
      fi
      echo "Invalid number: $selected" >&2
      continue
    fi
    if [[ -d "$root/releases/$selected" ]]; then
      echo "$selected"
      return 0
    fi
    echo "Release not found: $selected" >&2
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



