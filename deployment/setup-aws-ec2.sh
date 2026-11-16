#!/bin/bash
# =============================================================================
# NETGUARD AI — AWS EC2 Production Setup Script
# Ubuntu 22.04 LTS | Python 3.11 | Node 20 | Nginx | Uvicorn (systemd)
# Run as: sudo bash setup-aws-ec2.sh
# =============================================================================

set -e   # Exit immediately on any error

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
APP_DIR="/home/ubuntu/netguard-ai"
VENV_DIR="$APP_DIR/.venv"
SERVICE_USER="ubuntu"
BACKEND_PORT=8000
REPO_URL="https://github.com/Attharv17/NetGuard-AI.git"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       NETGUARD AI — AWS EC2 Deployment           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ── 0. Verify running as root ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run this script with sudo."

# ── 1. Configure 2 GB swap (prevents OOM on t2.micro / t3.micro) ─────────────
info "Step 1/9 — Configuring 2 GB swap memory..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    success "Swap created and activated."
else
    success "Swap already exists — skipping."
fi

# ── 2. System packages ────────────────────────────────────────────────────────
info "Step 2/9 — Installing system packages (Nginx, Python 3.11, build tools)..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    nginx \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3-pip \
    build-essential \
    git \
    curl \
    ca-certificates
success "System packages installed."

# ── 3. Node.js 20 (via NodeSource) ───────────────────────────────────────────
info "Step 3/9 — Installing Node.js 20..."
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d 'v') -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    success "Node.js $(node -v) installed."
else
    success "Node.js $(node -v) already present — skipping."
fi

# ── 4. Clone / update repository ──────────────────────────────────────────────
info "Step 4/9 — Cloning NetGuard-AI repository..."
if [ -d "$APP_DIR/.git" ]; then
    warn "Repository already exists — pulling latest changes..."
    sudo -u $SERVICE_USER git -C "$APP_DIR" pull --rebase origin main
else
    sudo -u $SERVICE_USER git clone "$REPO_URL" "$APP_DIR"
fi
success "Repository ready at $APP_DIR"

# ── 5. Python virtual environment + backend dependencies ─────────────────────
info "Step 5/9 — Creating Python venv and installing backend dependencies..."
sudo -u $SERVICE_USER python3.11 -m venv "$VENV_DIR"

# CPU-only PyTorch (keeps image lean on free-tier instances)
sudo -u $SERVICE_USER "$VENV_DIR/bin/pip" install --upgrade pip --quiet
sudo -u $SERVICE_USER "$VENV_DIR/bin/pip" install \
    torch --index-url https://download.pytorch.org/whl/cpu --quiet

sudo -u $SERVICE_USER "$VENV_DIR/bin/pip" install \
    -r "$APP_DIR/requirements.txt" --quiet

success "Python dependencies installed."

# ── 6. Build React frontend ───────────────────────────────────────────────────
info "Step 6/9 — Installing Node packages and building React production bundle..."
cd "$APP_DIR/frontend"
sudo -u $SERVICE_USER npm ci --prefer-offline --silent
sudo -u $SERVICE_USER npm run build
success "Frontend built to frontend/dist/"

# ── 7. Write production .env ──────────────────────────────────────────────────
info "Step 7/9 — Writing production environment file..."
SECRET_KEY=$(openssl rand -hex 32)
cat > "$APP_DIR/.env" <<EOF
# NETGUARD AI — Production Environment
APP_ENV=production
SECRET_KEY=${SECRET_KEY}
BACKEND_PORT=${BACKEND_PORT}
PYTHONPATH=${APP_DIR}
EOF
chown $SERVICE_USER:$SERVICE_USER "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
success "Production .env written."

# ── 8. Create & enable systemd service (Uvicorn) ─────────────────────────────
info "Step 8/9 — Setting up netguard-ai systemd service..."
cat > /etc/systemd/system/netguard-ai.service <<EOF
[Unit]
Description=NetGuard AI — FastAPI + Uvicorn Backend
After=network.target

[Service]
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${VENV_DIR}/bin/uvicorn backend.main:app \\
    --host 127.0.0.1 \\
    --port ${BACKEND_PORT} \\
    --workers 2 \\
    --log-level info
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable netguard-ai
systemctl restart netguard-ai
sleep 3

if systemctl is-active --quiet netguard-ai; then
    success "netguard-ai service is running."
else
    warn "Service may still be starting — check: journalctl -u netguard-ai -n 50"
fi

# ── 9. Configure Nginx ────────────────────────────────────────────────────────
info "Step 9/9 — Configuring Nginx reverse proxy..."
cat > /etc/nginx/sites-available/netguard-ai <<'EOF'
server {
    listen 80;
    server_name _;                         # Matches any hostname / raw IP

    client_max_body_size 50M;             # Allow CSV dataset uploads

    # ── API → Uvicorn ──────────────────────────────────────────────────────
    location /api/ {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }

    # ── Docs / OpenAPI (Swagger UI) ────────────────────────────────────────
    location /docs {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }

    location /openapi.json {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }

    # ── React SPA static assets (hashed filenames — long cache) ───────────
    location /assets/ {
        alias /home/ubuntu/netguard-ai/frontend/dist/assets/;
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # ── React SPA — catch-all (client-side routing) ────────────────────────
    location / {
        root   /home/ubuntu/netguard-ai/frontend/dist;
        index  index.html;
        try_files $uri $uri/ /index.html;
    }

    # ── Security headers ───────────────────────────────────────────────────
    add_header X-Frame-Options       "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy       "strict-origin" always;

    # ── Logging ────────────────────────────────────────────────────────────
    access_log /var/log/nginx/netguard-ai-access.log;
    error_log  /var/log/nginx/netguard-ai-error.log;
}
EOF

# Enable site, disable default placeholder
ln -sf /etc/nginx/sites-available/netguard-ai /etc/nginx/sites-enabled/netguard-ai
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

# ── Final health probe ────────────────────────────────────────────────────────
sleep 2
echo ""
info "Running health check on backend..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/api/health)
if [ "$HTTP_CODE" = "200" ]; then
    success "Backend health check passed (HTTP $HTTP_CODE)."
else
    warn "Backend returned HTTP $HTTP_CODE — it may still be warming up. Check logs below:"
    journalctl -u netguard-ai -n 20 --no-pager
fi

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "<your-ec2-public-ip>")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            NetGuard AI Deployment Successful! 🚀              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Dashboard :  http://${PUBLIC_IP}                        ║${NC}"
echo -e "${GREEN}║  API Docs  :  http://${PUBLIC_IP}/docs                   ║${NC}"
echo -e "${GREEN}║  Health    :  http://${PUBLIC_IP}/api/health              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Useful commands:                                             ║${NC}"
echo -e "${GREEN}║  sudo systemctl status netguard-ai                           ║${NC}"
echo -e "${GREEN}║  sudo journalctl -u netguard-ai -f                           ║${NC}"
echo -e "${GREEN}║  sudo tail -f /var/log/nginx/netguard-ai-error.log           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
