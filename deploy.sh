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
RSYNC_OPTS=(-avz --delete --exclude=.git --exclude=node_modules)
REMOTE_APP_BASE="/opt/my-blog"
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
if ssh -i $SSH_OPTS -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" 'echo SSH_OK' >/dev/null 2>&1; then
  log "SSH dry-run OK."
else
  err "SSH connectivity test failed. Ensure user/key/host are correct and accessible."
fi

# ---------------------------------------------------------
# Install Helper Function(will be executed on remote host)
# ---------------------------------------------------------
read -r -d '' REMOTE_SETUP_SCRIPT <<'REMOTE_EOF' || true
set -euo pipefail
# This script runs on the remote server (as the SSH user) and will:
# - create app directories
# - install Docker, docker-compose, and nginx (if missing)
# - add user to docker group (if sudo available)
# - enable and start services
APP_BASE_DIR='__REMOTE_APP_BASE__'
RELEASES_DIR='__REMOTE_RELEASES_DIR__'
CURRENT_LINK='__REMOTE_CURRENT_LINK__'
SSH_USER='__SSH_USER__'

log_remote(){ printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [REMOTE][INFO] %s" "$1"; }
err_remote(){ printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [REMOTE][ERROR] %s" "$1" >&2; exit 2; }

# Create directories
if sudo mkdir -p "$RELEASES_DIR" >/dev/null 2>&1; then
  sudo chown -R "$SSH_USER":"$SSH_USER" "$APP_BASE_DIR" || true
  log_remote "Created and set ownership for $APP_BASE_DIR"
else
  err_remote "Failed to create $APP_BASE_DIR"
fi

# Detect distro
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="$ID"
  DISTRO_LIKE="${ID_LIKE:-}"
else
  DISTRO=""
fi
log_remote "Detected distro: $DISTRO $DISTRO_LIKE"

install_package_debian() {
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_remote "Docker already installed: $(docker --version || true)"
    return
  fi
  log_remote "Installing Docker using get.docker.com script (remote)..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
}

install_docker_compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    log_remote "docker-compose already present: $(docker-compose --version || true)"
    return
  fi
  # Try to install docker-compose plugin first (docker compose)
  if docker --help | grep -q 'compose'; then
    log_remote "Docker Compose plugin is available via docker compose"
    return
  fi
  # Fallback to docker-compose binary
  COMPOSE_URL="https://github.com/docker/compose/releases/download/v2.40.1/docker-compose-$(uname -s)-$(uname -m)"
  sudo curl -L "$COMPOSE_URL" -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log_remote "nginx already installed: $(nginx -v 2>&1 || true)"
    return
  fi
  log_remote "Installing nginx..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y nginx
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y epel-release
    sudo yum install -y nginx
  else
    err_remote "No supported package manager found for nginx install"
  fi
  sudo systemctl enable --now nginx || true
}

# run installs (best-effort, idempotent)
if command -v apt-get >/dev/null 2>&1; then
  install_package_debian
fi
install_docker
install_docker_compose
install_nginx

# Add SSH user to docker group if sudo available
if id -nG "$SSH_USER" | grep -qw docker; then
  log_remote "User $SSH_USER already in docker group"
else
  sudo usermod -aG docker "$SSH_USER" || log_remote "usermod may have failed (non-critical); ensure $SSH_USER has docker access"
  log_remote "Added $SSH_USER to docker group (you may need to re-login for group to apply)"
fi

# Ensure services enabled
sudo systemctl enable --now docker || true
if command -v nginx >/dev/null 2>&1; then
  sudo systemctl enable --now nginx || true
fi

# Print versions
docker --version || true
docker-compose --version || true
nginx -v 2>/dev/null || true

REMOTE_EOF

# Replace placeholders with real values (careful with quoting)
REMOTE_SETUP_SCRIPT="${REMOTE_SETUP_SCRIPT//__REMOTE_APP_BASE__/$REMOTE_APP_BASE}"
REMOTE_SETUP_SCRIPT="${REMOTE_SETUP_SCRIPT//__REMOTE_RELEASES_DIR__/$REMOTE_RELEASES_DIR}"
REMOTE_SETUP_SCRIPT="${REMOTE_SETUP_SCRIPT//__REMOTE_CURRENT_LINK__/$REMOTE_CURRENT_LINK}"
REMOTE_SETUP_SCRIPT="${REMOTE_SETUP_SCRIPT//__SSH_USER__/$SSH_USER}"

log "Executing remote setup script to prepare environment (install Docker, docker-compose, nginx where needed)..."
# Use ssh and pipe script in to avoid storing it on disk
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" 'bash -s' <<EOF 2>>"$LOGFILE"
$REMOTE_SETUP_SCRIPT
EOF

log "Remote environment prepared."


# ------------------------------------------------------------
# Task 6: Deploy the Dockerized Application (transfer files & run)
# ------------------------------------------------------------
# Create a remote release dir name
RELEASE_NAME="${GIT_BRANCH//\//-}-${TIMESTAMP}"
REMOTE_RELEASE_DIR="${REMOTE_RELEASES_DIR}/${RELEASE_NAME}"

log "Transferring project files to remote: ${SSH_USER}@${SSH_HOST}:${REMOTE_RELEASE_DIR}"
# create remote release directory
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "mkdir -p '${REMOTE_RELEASE_DIR}' && chown -R ${SSH_USER}:${SSH_USER} '${REMOTE_RELEASE_DIR}'" || err "Failed to create remote release directory"

# rsync to remote (will exclude .git and node_modules by RSYNC_OPTS)
#rsync -e "ssh -i $SSH_OPTS" $RSYNC_OPTS ./ "${SSH_USER}@${SSH_HOST}:${REMOTE_RELEASE_DIR}/" >>"$LOGFILE" 2>&1 || err "rsync of project files failed"
# Run rsync with better quoting and capture error
if ! rsync -avz --delete --exclude=.git -e "ssh -i '$SSH_KEY_PATH' $SSH_OPTS" ./ "${SSH_USER}@${SSH_HOST}:${REMOTE_RELEASE_DIR}/" >>"$LOGFILE" 2>&1; then
    warn "rsync failed. Dumping last 20 log lines for inspection:"
    tail -n 20 "$LOGFILE"
    error "rsync of project files failed (check SSH key, remote permissions, or rsync availability)"
fi

log "Files transferred. Setting proper permissions on remote release dir..."
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "chmod -R g+rX,o-rwx '${REMOTE_RELEASE_DIR}' || true" || warn "Failed to set remote permissions"

# Link current -> new release atomically
log "Updating current symlink to point to new release..."
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "ln -sfn '${REMOTE_RELEASE_DIR}' '${REMOTE_CURRENT_LINK}' && chown -h ${SSH_USER}:${SSH_USER} '${REMOTE_CURRENT_LINK}'" || warn "Failed to update current symlink"

# Decide deployment method: docker-compose if file exists, else Dockerfile build + run
REMOTE_COMPOSE_PATH="${REMOTE_CURRENT_LINK}/docker-compose.yml"
REMOTE_DOCKERFILE_PATH="${REMOTE_CURRENT_LINK}/Dockerfile"
DEPLOY_WITH_COMPOSE=false

# Check remote files existence
if ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "[ -f '${REMOTE_COMPOSE_PATH}' ]" >/dev/null 2>&1; then
  DEPLOY_WITH_COMPOSE=true
  log "Detected docker-compose on remote deployment path."
elif ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "[ -f '${REMOTE_CURRENT_LINK}/docker-compose.yaml' ]" >/dev/null 2>&1; then
  DEPLOY_WITH_COMPOSE=true
  REMOTE_COMPOSE_PATH="${REMOTE_CURRENT_LINK}/docker-compose.yaml"
fi

# remote deployment script (build/run) - idempotent: docker-compose down/up or docker rm/run
read -r -d '' REMOTE_DOCKER_SCRIPT <<'REMOTE_DOCKER_EOF' || true
set -euo pipefail
APP_DIR='__APP_DIR__'
USE_COMPOSE='__USE_COMPOSE__'
SERVICE_NAME='myapp'   # container name used for simple docker run path; adapt as needed
INTERNAL_PORT='__APP_INTERNAL_PORT__'
log_remote(){ printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [REMOTE][DEPLOY] %s" "$1"; }
err_remote(){ printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z') [REMOTE][DEPLOY][ERROR] %s" "$1" >&2; exit 3; }

cd "$APP_DIR"
pwd
ls -la $APP_DIR

if [[ "$USE_COMPOSE" == "true" ]]; then
  # bring down previous stack gracefully (idempotent)
  if command -v docker-compose >/dev/null 2>&1; then
    log_remote "Using docker-compose to deploy (docker-compose down/up)"
    docker-compose -f "$APP_DIR/docker-compose.yml" down --remove-orphans || log_remote "docker-compose down non-fatal"
    docker-compose -f "$APP_DIR/docker-compose.yml" pull || log_remote "docker-compose pull (may be missing images)"
    docker-compose -f "$APP_DIR/docker-compose.yml" up -d --remove-orphans --build
  else
    # Try docker compose plugin
    docker compose -f "$APP_DIR/docker-compose.yml" down --remove-orphans || true
    docker compose -f "$APP_DIR/docker-compose.yml" pull || true
    docker compose -f "$APP_DIR/docker-compose.yml" up -d --remove-orphans --build
  fi
else
  # Single Dockerfile flow: build image and run container as 'my-blog'
  IMAGE_TAG="myapp:${APP_DIR##*/}"
  log_remote "Building image ${IMAGE_TAG}"
  docker build -t "$IMAGE_TAG" "$APP_DIR"
  # stop and remove existing container if exists
  if docker ps -a --format '{{.Names}}' | grep -w "$SERVICE_NAME" >/dev/null 2>&1; then
    docker rm -f "$SERVICE_NAME" || log_remote "Failed to remove existing container (non-fatal)"
  fi
  # run container (expose internal port to host ephemeral or same port)
  docker run -d --restart unless-stopped --name "$SERVICE_NAME" -p 127.0.0.1:${INTERNAL_PORT}:${INTERNAL_PORT} "$IMAGE_TAG"
fi

REMOTE_DOCKER_EOF

REMOTE_DOCKER_SCRIPT="${REMOTE_DOCKER_SCRIPT//__APP_DIR__/$REMOTE_CURRENT_LINK}"
REMOTE_DOCKER_SCRIPT="${REMOTE_DOCKER_SCRIPT//__USE_COMPOSE__/$DEPLOY_WITH_COMPOSE}"
REMOTE_DOCKER_SCRIPT="${REMOTE_DOCKER_SCRIPT//__APP_INTERNAL_PORT__/$APP_INTERNAL_PORT}"

log "Executing remote deployment script..."
# replace placeholder in the heredoc with actual content in a safe way
# But simpler: using direct heredoc above is messy; instead run with variable expansion:
if [[ "$REMOTE_DOCKER_SCRIPT" == *"__APP_DIR__"* ]]; then
    err "Placeholder substitution failed (found __APP_DIR__ still in script)"
fi
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" 'bash -s' <<EOF 2>>"$LOGFILE"
$REMOTE_DOCKER_SCRIPT
EOF

log "Remote containers started."

# -----------------------------------------
# Task 7: Configure Nginx as Reverse Proxy
# -----------------------------------------
log "Configuring Nginx reverse proxy on remote to forward port 80 -> container port ${APP_INTERNAL_PORT}"

# Build nginx config (supports Debian/Ubuntu and RHEL by placing in appropriate directory)
read -r -d '' NGINX_CONF_TEMPLATE <<'NGINX_CONF' || true
server {
    listen 80;
    server_name _;
    # Proxy to local app container
    location / {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5;
        proxy_read_timeout 60;
    }

    # SSL readiness placeholder:
    # To enable SSL, install certbot and adjust below to listen 443 and provide ssl_certificate paths.
    # Example (self-signed or certbot-managed) can be added here.
}
NGINX_CONF

NGINX_CONF="${NGINX_CONF//__APP_PORT__/$APP_INTERNAL_PORT}"

# Remote placement: prefer /etc/nginx/sites-available and sites-enabled (Debian), otherwise /etc/nginx/conf.d
NGINX_REMOTE_PATH_DEBIAN="/etc/nginx/sites-available/${NGINX_SITE_NAME}.conf"
NGINX_REMOTE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}.conf"
NGINX_REMOTE_PATH_CONF_D="/etc/nginx/conf.d/${NGINX_SITE_NAME}.conf"

# Create temp file locally then rsync to remote
TMP_NGINX="/tmp/${NGINX_SITE_NAME}_${TIMESTAMP}.conf"
printf "%s\n" "$NGINX_CONF" > "$TMP_NGINX"

# Upload config to remote in the best location detected
# Detect remote OS and write appropriate path
REMOTE_NGINX_TARGET="$NGINX_REMOTE_PATH_CONF_D"  # default
if ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "[ -d /etc/nginx/sites-available ]" >/dev/null 2>&1; then
  REMOTE_NGINX_TARGET="$NGINX_REMOTE_PATH_DEBIAN"
fi

rsync -e "ssh -i $SSH_OPTS" "$TMP_NGINX" "${SSH_USER}@${SSH_HOST}:/tmp/${NGINX_SITE_NAME}.conf" >>"$LOGFILE" 2>&1 || err "Failed to upload nginx config"

# Move config into place and enable
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" bash -se <<'REMOTE_NGINX' 2>>"$LOGFILE"
set -euo pipefail
TARGET="${1}"
SITE_AVAILABLE="/etc/nginx/sites-available/__NGINX_SITE_NAME__"
SITE_ENABLED="/etc/nginx/sites-enabled/__NGINX_SITE_NAME__"
TMP="/tmp/__NGINX_SITE_NAME__.conf"
if [ -d /etc/nginx/sites-available ]; then
  sudo mv "$TMP" "$SITE_AVAILABLE"
  sudo ln -sf "$SITE_AVAILABLE" "$SITE_ENABLED"
  sudo chmod 644 "$SITE_AVAILABLE"
else
  sudo mv "$TMP" "$TARGET"
  sudo chmod 644 "$TARGET"
fi
# Test nginx config
if sudo nginx -t; then
  sudo systemctl reload nginx || true
else
  echo "NGINX_TEST_FAILED" >&2
  exit 5
fi
REMOTE_NGINX
# pass TARGET
# replace placeholders by shell parameter expansion
# But we need to pass the correct args; simpler to inject proper values using env expansion:
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" bash -se <<EOF 2>>"$LOGFILE"
set -euo pipefail
TARGET="${REMOTE_NGINX_TARGET}"
SITE_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE_NAME}.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}.conf"
TMP="/tmp/${NGINX_SITE_NAME}.conf"
if [ -d /etc/nginx/sites-available ]; then
  sudo mv "\$TMP" "\$SITE_AVAILABLE"
  sudo ln -sf "\$SITE_AVAILABLE" "\$SITE_ENABLED"
  sudo chmod 644 "\$SITE_AVAILABLE"
else
  sudo mv "\$TMP" "\$TARGET"
  sudo chmod 644 "\$TARGET"
fi
if sudo nginx -t; then
  sudo systemctl reload nginx || true
else
  echo "NGINX_TEST_FAILED" >&2
  exit 5
fi
EOF

log "Nginx configured and reloaded."

# ---------------------------
# Task 8: Validate Deployment
# ---------------------------
log "Validating deployment: checking Docker service, container health, and nginx proxy..."

# 8a. Docker service
if ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "sudo systemctl is-active --quiet docker"; then
  log "Docker service is active on remote."
else
  warn "Docker service not active; attempting to start..."
  ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "sudo systemctl enable --now docker" || warn "Failed to start Docker"
fi

# 8b. Container health: prefer docker inspect health, else check that container exists and port is listening
SSH_CHECK_HEALTH_COMMAND="
set -euo pipefail
cd '${REMOTE_CURRENT_LINK}'
# try common names: docker-compose uses service names; try 'myapp' fallback
CONTAINERS=\$(docker ps --format '{{.Names}}')
# If health status exists, print it:
for c in \$CONTAINERS; do
  H=\$(docker inspect --format '{{json .State.Health}}' \"\$c\" 2>/dev/null || true)
  if [[ -n \"\$H\" && \"\$H\" != \"null\" ]]; then
    echo \"CONTAINER:\$c HEALTH:\$H\"
  fi
done
# Check if any container maps to the internal port on 127.0.0.1
ss -ltnp 2>/dev/null | grep -E \":${APP_INTERNAL_PORT} \" || true
"
log "Inspecting containers on remote..."
ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "$SSH_CHECK_HEALTH_COMMAND" >>"$LOGFILE" 2>&1 || warn "Container health check command returned non-zero (non-fatal)"

# 8c. Test endpoint via curl from remote (localhost) and from local machine
log "Testing HTTP endpoint from remote (curl http://127.0.0.1:${APP_INTERNAL_PORT})..."
REMOTE_CURL_TEST=$(ssh -i $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "curl -I --max-time 5 http://127.0.0.1:${APP_INTERNAL_PORT} 2>/dev/null || true" || true)
if [[ -n "$REMOTE_CURL_TEST" ]]; then
  log "Remote localhost curl succeeded (headers):"
  printf "%s\n" "$REMOTE_CURL_TEST" | sed -n '1,10p' | tee -a "$LOGFILE"
else
  warn "Remote curl to app internal port returned no response."
fi

log "Testing public HTTP via Nginx from local (curl -I --max-time 10 http://${SSH_HOST}/ )..."
LOCAL_NGINX_TEST=$(curl -I --max-time 10 "http://${SSH_HOST}/" 2>/dev/null || true)
if [[ -n "$LOCAL_NGINX_TEST" ]]; then
  log "Public curl via nginx succeeded (headers):"
  printf "%s\n" "$LOCAL_NGINX_TEST" | sed -n '1,10p' | tee -a "$LOGFILE"
else
  warn "Public curl to http://${SSH_HOST}/ failed or timed out. Check firewall, security groups, or nginx config."
fi


