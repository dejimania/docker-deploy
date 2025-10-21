#!/usr/bin/env bash
# deploy.sh
# Production-ready docker deployment script.
# Usage: ./deploy.sh
# Optional flags:
#   --cleanup     : run cleanup procedure on remote (remove containers, nginx config, project dir)
#   --non-interactive : don't prompt for confirmations (useful for CI; still prompts for required secrets unless provided via env)

# Make pipelines fail if any command in this script fails
# Sets the Internal Field Separator to only newline and tab
set -euo pipefail
IFS=$'\n\t'

# ---------------------------
# Configuration / defaults
# ---------------------------
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
LOGFILE="./deploy_${TIMESTAMP}.log"
KEEP_LOGS=30
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
RSYNC_OPTS="-az --delete --exclude=.git --exclude=node_modules"
REMOTE_APP_BASE="/opt/myapp"
REMOTE_RELEASES_DIR="${REMOTE_APP_BASE}/releases"
REMOTE_CURRENT_LINK="${REMOTE_APP_BASE}/current"
NGINX_SITE_NAME="my-blog"
CLEANUP_MODE=false
NONINTERACTIVE=false