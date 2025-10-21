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

# ---------------------------
# Helper functions (logging, secret_masking, init, prompt, execs)
# ---------------------------
log() { printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [INFO]  %s" "$*" | tee -a "$LOGFILE"; }
warn() { printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [WARN]  %s" "$*" | tee -a "$LOGFILE" >&2; }
err() { printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [ERROR] %s" "$*" | tee -a "$LOGFILE" >&2; exit "${2:-1}"; }
debug() { printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [DEBUG] %s" "$*" >>"$LOGFILE"; }
mask_secret() { local s="$1"; if [[ -z "$s" ]]; then echo ""; else echo "${s:0:4}***${s: -4}"; fi }

# ensures the logfile exists and is writable
init_log() {
  touch "$LOGFILE" || { echo "Cannot write log to $LOGFILE"; exit 2; }
  # prune old logs
  (ls -1tr ./deploy_*.log 2>/dev/null | head -n -"$KEEP_LOGS" || true) | xargs -r rm -f || true
  log "Deployment started. Logfile: $LOGFILE"
}

# safe prompt (supports non-interactive)
prompt() {
  local varname="$1"; local prompt_msg="$2"; local default="${3:-}"
  if $NONINTERACTIVE && [[ -n "${!varname:-}" ]]; then
    return 0
  fi
  if $NONINTERACTIVE && [[ -z "${!varname:-}" ]]; then
    err "Non-interactive and required variable $varname is not set"
  fi
  # interactive prompt
  if [[ "$varname" == "GIT_PAT" ]]; then
    # secret
    read -rs -p "$prompt_msg: " val
    echo
  else
    if [[ -n "$default" ]]; then
      read -r -p "$prompt_msg [$default]: " val
      val="${val:-$default}"
    else
      read -r -p "$prompt_msg: " val
    fi
  fi
  printf -v "$varname" '%s' "$val"
}

# run a command remotely via ssh (returns output or error)
remote_exec() {
  local user="$1"; local host="$2"; shift 2
  ssh $SSH_OPTS "${user}@${host}" -- "$@" 2>>"$LOGFILE"
}

# run a script on remote host via SSH heredoc
remote_exec_script() {
  local user="$1"; local host="$2"; local script="$3"
  ssh $SSH_OPTS "${user}@${host}" bash -se <<'REMOTE' 2>>"$LOGFILE"
$(cat <<'INNER'
__SCRIPT__
INNER
)
REMOTE
}

# wrapper for safer ssh with heredoc; we'll create the heredoc dynamically in-place later
ssh_run() {
  local user="$1"; local host="$2"; shift 2
  ssh $SSH_OPTS "${user}@${host}" -- "$@" 2>>"$LOGFILE"
}

# check ssh connectivity without running a lingering remote command
check_ssh_connectivity() {
  local user="$1"; local host="$2"
  log "Checking SSH connectivity to ${user}@${host}"
  if ssh $SSH_OPTS -o BatchMode=yes "${user}@${host}" 'echo SSH_OK' >/dev/null 2>&1; then
    log "SSH connectivity OK"
  else
    err "SSH connectivity failed to ${user}@${host}. Check network, credentials and key permissions."
  fi
}

# small helper to test remote command and capture stdout
remote_out() {
  local user="$1"; local host="$2"; shift 2
  ssh $SSH_OPTS "${user}@${host}" -- "$@" 2>>"$LOGFILE"
}

# ---------------------------
# Argument parsing
# ---------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP_MODE=true; shift;;
    --non-interactive) NONINTERACTIVE=true; shift;;
    -h|--help) echo "Usage: $SCRIPT_NAME [--cleanup] [--non-interactive]"; exit 0;;
    *) err "Unknown arg: $1";;
  esac
done

init_log

# ---------------------------------------
# Task 1: Gather user input and validate
# ---------------------------------------
log "Collecting deployment parameters..."

# Prompt for parameters (unless environment variables already set and non-interactive requested).
prompt GIT_REPO_URL "Git repository HTTPS URL (e.g. https://github.com/your_org/repo.git)"
prompt GIT_PAT "Git Personal Access Token (will not be echoed; keep secret)"
prompt GIT_BRANCH "Branch name (default: main)" "main"

prompt SSH_USER "Remote SSH username (e.g. ubuntu, ec2-user)"
prompt SSH_HOST "Remote server IP or hostname (e.g. 184.21.3.50)"
prompt SSH_KEY_PATH "Path to private SSH key (leave blank to use default ssh-agent)" ""

prompt APP_INTERNAL_PORT "Application internal port inside container (e.g. 80, 3000)" "3000"

# optional values
prompt PROJECT_DIR_NAME "Optional: local directory name to clone into (leave blank to use repo name derived from URL)" ""
# enabling use of non-interactive envs as fallback
GIT_REPO_URL="${GIT_REPO_URL}"
GIT_PAT="${GIT_PAT}"
GIT_BRANCH="${GIT_BRANCH:-main}"
SSH_USER="${SSH_USER}"
SSH_HOST="${SSH_HOST}"
SSH_KEY_PATH="${SSH_KEY_PATH}"
APP_INTERNAL_PORT="${APP_INTERNAL_PORT}"
PROJECT_DIR_NAME="${PROJECT_DIR_NAME}"

log "Parameters summary (sensitive values masked):"
log "  Repo URL: $GIT_REPO_URL"
log "  Branch: $GIT_BRANCH"
log "  Git PAT: $(mask_secret "$GIT_PAT")"
log "  SSH target: ${SSH_USER}@${SSH_HOST}"
log "  SSH key: ${SSH_KEY_PATH:-(ssh-agent/default)}"
log "  App internal port: ${APP_INTERNAL_PORT}"
log "  Local project dir: ${PROJECT_DIR_NAME:-(derived from repo)}"

# Minimal validation
if [[ -z "$GIT_REPO_URL" || -z "$GIT_PAT" || -z "$SSH_USER" || -z "$SSH_HOST" ]]; then
  err "Missing required parameters. Exiting."
fi

# If SSH key path specified, ensure file exists and add to ssh-agent for this script
if [[ -n "${SSH_KEY_PATH:-}" ]]; then
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    err "SSH key file not found at $SSH_KEY_PATH"
  fi
  log "Using SSH key: $SSH_KEY_PATH"
  # ensure ssh-agent running, try to add key (silently)
  eval "$(ssh-agent -s)" >/dev/null 2>&1 || true
  ssh-add -l >/dev/null 2>&1 || true
  ssh-add "$SSH_KEY_PATH" >/dev/null 2>&1 || warn "Unable to add SSH key to ssh-agent; ensure agent is running"
fi

# --------------------------------------------
# Task 2: Clone the repository or pull latest
# --------------------------------------------
log "Preparing local repository clone/pull..."

# derive repo name if not provided
if [[ -z "$PROJECT_DIR_NAME" ]]; then
  # parse repo name from URL
  repo_name="$(basename -s .git "${GIT_REPO_URL}")"
else
  repo_name="$PROJECT_DIR_NAME"
fi

# Use a temporary sanitized URL to avoid logging PAT; build an auth URL for git
# Note: We will not print the auth URL to logs; only use in command pipeline.
# The common pattern: https://<token>@github.com/user/repo.git
AUTH_GIT_URL="${GIT_REPO_URL/https:\/\//https:\/\/x-access-token:${GIT_PAT}@}"

if [[ -d "$repo_name/.git" ]]; then
  log "Local repo $repo_name exists — fetching latest"
  pushd "$repo_name" >/dev/null
  # set remote origin to the auth url temporarily to fetch
  git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$AUTH_GIT_URL" || git remote add origin "$AUTH_GIT_URL"
  git fetch --prune origin "$GIT_BRANCH" >>"$LOGFILE" 2>&1 || err "git fetch failed"
  git checkout "$GIT_BRANCH" >>"$LOGFILE" 2>&1 || err "git checkout $GIT_BRANCH failed"
  git pull origin "$GIT_BRANCH" >>"$LOGFILE" 2>&1 || err "git pull failed"
  # restore remote URL to non-auth version to avoid leaving PAT in config
  git remote set-url origin "$GIT_REPO_URL" >>"$LOGFILE" 2>&1 || true
  popd >/dev/null
  log "Repository updated locally."
else
  log "Cloning repository (branch: $GIT_BRANCH) into $repo_name"
  # clone only the requested branch for speed
  git clone --branch "$GIT_BRANCH" --single-branch "$AUTH_GIT_URL" "$repo_name" >>"$LOGFILE" 2>&1 || err "git clone failed"
  # remove PAT from git config by setting remote URL back
  pushd "$repo_name" >/dev/null
  git remote set-url origin "$GIT_REPO_URL" >>"$LOGFILE" 2>&1 || true
  popd >/dev/null
  log "Repository cloned."
fi

# ---------------------------------------------------------------------------
# Task 3: Navigate into cloned directory and check Dockerfile/docker-compose
# ---------------------------------------------------------------------------
cd "$repo_name"
log "Changed working directory to $(pwd)"
if [[ -f "Dockerfile" ]]; then
  log "Found Dockerfile."
fi
if [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]]; then
  log "Found docker-compose file."
fi
if [[ ! -f "Dockerfile" && ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
  warn "Neither Dockerfile nor docker-compose.yml found in repository root. Cannot continue deployment."
  err "Missing Dockerfile or docker-compose.yml"
fi

# --------------------------------------------------------
# Task 4: SSH into the remote server: connectivity checks
# --------------------------------------------------------
log "Checking remote connectivity..."
# quick ping (optional) then SSH dry-run
if ping -c 1 -W 2 "$SSH_HOST" >/dev/null 2>&1; then
  log "Ping to ${SSH_HOST} succeeded."
else
  warn "Ping to ${SSH_HOST} failed or blocked; will proceed to SSH check."
fi

# Test SSH connection (non-interactive)
if ssh $SSH_OPTS -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" 'echo SSH_OK' >/dev/null 2>&1; then
  log "SSH dry-run OK."
else
  err "SSH connectivity test failed. Ensure user/key/host are correct and accessible."
fi

