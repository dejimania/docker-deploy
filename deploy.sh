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

