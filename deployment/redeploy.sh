#!/bin/bash
# =============================================================================
# NETGUARD AI — Zero-downtime Redeploy Script (run on EC2 when you push code)
# Usage: sudo bash redeploy.sh
# =============================================================================

set -e
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

APP_DIR="/home/ubuntu/netguard-ai"
VENV_DIR="$APP_DIR/.venv"
SERVICE_USER="ubuntu"

info "Pulling latest code..."
sudo -u $SERVICE_USER git -C "$APP_DIR" pull --rebase origin main

info "Installing any new Python dependencies..."
sudo -u $SERVICE_USER "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" --quiet

info "Rebuilding React frontend..."
cd "$APP_DIR/frontend"
sudo -u $SERVICE_USER npm ci --prefer-offline --silent
sudo -u $SERVICE_USER npm run build

info "Restarting netguard-ai service..."
systemctl restart netguard-ai

info "Reloading Nginx..."
systemctl reload nginx

sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/api/health)
success "Redeploy complete — backend health: HTTP $HTTP_CODE"
