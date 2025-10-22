# 🚀 Automated Docker Deployment Script

## Overview

This project provides a **production-grade Bash automation script** that fully automates the setup, deployment, and configuration of a **Dockerized application** on a **remote Linux server**.  
It also handles environment preparation, Nginx reverse proxy configuration, and robust error handling with detailed logging.

---

## 🧩 Features

✅ **Automated End-to-End Deployment** — From cloning the Git repo to running the container.  
✅ **Supports Docker and Docker Compose** — Automatically detects which to use.  
✅ **Remote Server Setup** — Installs Docker, Docker Compose, and Nginx if missing.  
✅ **Nginx Reverse Proxy** — Dynamically creates a reverse proxy forwarding HTTP traffic to your container.  
✅ **Error Handling & Logging** — Every step logs to `deploy_<timestamp>.log`.  
✅ **Idempotent Execution** — Safe to re-run multiple times without breaking existing setup.  
✅ **Clean Rollbacks** — Gracefully stops or replaces old containers and configs.  

---

## 🧱 Prerequisites

### On Your Local Machine
- **Bash 4+**
- **Git**
- **rsync**
- **SSH access** to the remote host (key-based authentication recommended)

### On the Remote Host
- **Linux (Ubuntu/Debian/CentOS/RHEL)**
- **sudo privileges** for the SSH user
- **Port 22** open for SSH
- **Port 80** open for HTTP (and optionally 443 for HTTPS)

---

## ⚙️ Setup Instructions

1. **Clone this repository**
   ```bash
   git clone <this-repo-url>
   cd <repo-directory>

2. **Make the script executable:**
   ```bash
   chmod +x deploy.sh
   ```

3. **Run the deployment:**
   ```bash
   ./deploy.sh
   ```

4. **Monitor logs:**
   ```bash
   tail -f deploy.log
   ```

5. **Provide required inputs interactively**:
- **Git Repository URL**
- **Personal Access Token (PAT)**
- **Branch name (defaults to main)**
- **Remote Server SSH username**
- **Server IP Address**
- **SSH key path (e.g., ~/.ssh/id_rsa)**
- **Application internal port (e.g., 3000)**


---

## 🔄 What the Script Does

| Step | Task | Description |
|------|------|-------------|
| 1 | Validate environment | Checks required tools and variables |
| 2 | Prepare remote host | Installs Docker & Nginx if not found |
| 3 | Sync project files | Uses rsync to copy source code to remote |
| 4 | Build & Run Docker container | Builds image and launches container |
| 5 | Configure Nginx | Creates and installs reverse proxy config |
| 6 | Verify | Tests Nginx configuration and restarts service |

---

---

## 🧩 Troubleshooting

| Issue | Possible Cause | Fix |
|-------|----------------|-----|
| `rsync of project files failed` | Missing SSH key or incorrect path | Verify `$SSH_KEY_PATH` and permissions |
| `REMOTE_NGINX_TARGET: unbound variable` | Variable not set before use | Ensure initialization before SSH commands |
| `Remote nginx config/reload failed` | Nginx config test failed | Run `sudo nginx -t` on remote to debug |

---


---

## 🧾 License

GPL License © 2025

You are free to use, modify, and distribute this script with attribution.

---

## 💬 Author

**Kamil Balogun**  
DevOps / Cloud Engineer  
📧 kamilbalogun@hotmail.com  
🐙 GitHub: [dejimania](https://github.com/dejimania)