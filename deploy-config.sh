# Patet deployment paths and defaults (sourced by deploy-common.sh; do not execute directly).
# Override on the server or in deploy.local.env (Windows) via PATET_* variables.

PATET_API_ROOT="${PATET_API_ROOT:-/var/www/patet-api}"
PATET_WEB_ROOT="${PATET_WEB_ROOT:-/var/www/patet-website}"
PATET_DEPLOYMENT_ROOT="${PATET_DEPLOYMENT_ROOT:-/var/www/patet-deployment}"

API_ROOT="$PATET_API_ROOT"
WEB_ROOT="$PATET_WEB_ROOT"

API_REPO="${API_REPO:-git@bitbucket.org:we-dotech/patet-back-nestjs.git}"
WEB_REPO="${WEB_REPO:-git@bitbucket.org:we-dotech/patet-website.git}"

API_BRANCH="${API_BRANCH:-sevak_develop}"
WEB_BRANCH="${WEB_BRANCH:-develop_intermediate}"

PM2_ECOSYSTEM="${PM2_ECOSYSTEM:-$PATET_DEPLOYMENT_ROOT/ecosystem.config.js}"

BACKEND_HEALTH_URL="${BACKEND_HEALTH_URL:-http://127.0.0.1:57303/api/v1/auth/me}"
FRONTEND_HEALTH_URL="${FRONTEND_HEALTH_URL:-http://127.0.0.1:4993/}"

BACKEND_VERIFY_MAX_ATTEMPTS="${BACKEND_VERIFY_MAX_ATTEMPTS:-40}"
BACKEND_VERIFY_SLEEP_SECS="${BACKEND_VERIFY_SLEEP_SECS:-2}"
FRONTEND_VERIFY_MAX_ATTEMPTS="${FRONTEND_VERIFY_MAX_ATTEMPTS:-40}"
FRONTEND_VERIFY_SLEEP_SECS="${FRONTEND_VERIFY_SLEEP_SECS:-2}"

KEEP_DISTINCT_SUCCESSFUL_SHAS="${KEEP_DISTINCT_SUCCESSFUL_SHAS:-5}"

# Yarn Classic cache for server installs. Empty = `yarn cache dir` (usually ~/.cache/yarn).
# Deploy never runs `yarn cache clean`. Override to a shared path if needed.
# PATET_YARN_CACHE_DIR=/var/www/.yarn-cache
#
# Set PATET_FORCE_YARN_INSTALL=1 after a Node upgrade or if node_modules looks corrupt.
PATET_YARN_CACHE_DIR="${PATET_YARN_CACHE_DIR:-}"
PATET_FORCE_YARN_INSTALL="${PATET_FORCE_YARN_INSTALL:-0}"

BACKEND_SHARED_FILES=(
  ".env"
  "ca-certificate.crt"
)

FRONTEND_SHARED_FILES=(
  ".env"
)

# Demo MP4s live here once per VPS; each release symlinks public/assets/videos -> this dir.
WEB_SHARED_VIDEOS_DIR="${WEB_SHARED_VIDEOS_DIR:-$WEB_ROOT/shared/assets-videos}"
