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
   chmod +x deploy.sh

2. **Run the deployment script**
./deploy.sh

3. **Provide required inputs interactively**:
- **Git Repository URL**
- **Personal Access Token (PAT)**
- **Branch name (defaults to main)**
- **Remote Server SSH username**
- **Server IP Address**
- **SSH key path (e.g., ~/.ssh/id_rsa)**
- **Application internal port (e.g., 3000)**

4. **The script will**:
- **Validate inputs**
- **Clone or pull your repository**
- **SSH into your remote server**
- **Install and configure Docker, Docker Compose, and Nginx**
- **Transfer project files**
- **Build and run your Docker containers**
- **Configure Nginx to reverse-proxy http://<server-ip> → 127.0.0.1:<container-port>**
- **Validate that the app and Nginx are running correctly**
