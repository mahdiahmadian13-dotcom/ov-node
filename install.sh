#!/bin/bash
#=============================================================
# OV-Node Quick Installer
# One-line install: bash <(curl -s https://raw.githubusercontent.com/primeZdev/ov-node/main/install.sh)
#=============================================================

set -e

REPO_URL="https://github.com/primeZdev/ov-node"
INSTALL_DIR="/opt/ov-node"
BRANCH="main"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              OV-Node Quick Installer                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "[✗] Please run as root"
    exit 1
fi

# Install dependencies
echo "[→] Installing dependencies..."
apt update -y
apt install -y python3 python3-pip python3-venv wget curl git pexpect

# Install uv if not present
if ! command -v uv &> /dev/null; then
    echo "[→] Installing uv..."
    wget -qO- https://astral.sh/uv/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# Clone or update repository
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "[→] Updating OV-Node..."
    cd "$INSTALL_DIR"
    git pull
else
    echo "[→] Cloning OV-Node..."
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Install Python dependencies
echo "[→] Installing Python dependencies..."
uv sync

# Generate API key
API_KEY=$(openssl rand -hex 32)

# Create .env file
cat > "${INSTALL_DIR}/.env" << EOF
SERVICE_PORT=9090
API_KEY=${API_KEY}
DEBUG=WARNING
DOC=False
EOF

# Create systemd service
PYTHON_PATH="${INSTALL_DIR}/.venv/bin/python"

cat > /etc/systemd/system/ov-node.service << EOF
[Unit]
Description=OV-Node Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=/root/.local/bin:${INSTALL_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/root/.local/bin/uv run main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload and start
systemctl daemon-reload
systemctl enable ov-node
systemctl start ov-node

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           Installation Complete!                          ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "Connection Information:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Node Address:  $(curl -s ifconfig.me):9090"
echo "  API Key:       ${API_KEY}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Useful Commands:"
echo "  systemctl status ov-node    # Check status"
echo "  journalctl -u ov-node -f    # View logs"
echo ""
