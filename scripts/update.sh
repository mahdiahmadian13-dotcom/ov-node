#!/bin/bash
#=============================================================
# OV-Node Updater
# Updates OV-Node from GitHub repository
#=============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

OVNODE_DIR="/opt/ov-node"
REPO_URL="https://github.com/primeZdev/ov-node"
BRANCH="main"

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${CYAN}[→]${NC} $1"; }

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              OV-Node Updater                             ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check if OV-Node is installed
if [ ! -d "$OVNODE_DIR" ]; then
    log_error "OV-Node is not installed at $OVNODE_DIR"
    exit 1
fi

cd "$OVNODE_DIR"

# Handle tarball deployments without .git: convert to git repo
if [ ! -d ".git" ]; then
    log_warn "No git repository found (tarball install). Converting..."
    git init -q
    git remote add origin "$REPO_URL" 2>/dev/null || true
    git fetch origin "$BRANCH" 2>/dev/null
    git reset --hard "origin/$BRANCH" 2>/dev/null || true
fi

# Get current version
CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
log_info "Current version: $CURRENT_COMMIT"

# Step 1: Backup current .env
log_step "Backing up configuration..."
if [ -f ".env" ]; then
    cp .env .env.backup
    log_info "Configuration backed up"
fi

# Step 2: Fetch updates
log_step "Fetching updates from GitHub..."
git fetch origin "$BRANCH" 2>&1

# Check for updates
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
    log_info "Already up to date!"
    echo ""
    echo "Current version: $(git rev-parse --short HEAD)"
    exit 0
fi

# Show what's new
echo ""
echo "New commits available:"
git log --oneline "$LOCAL..$REMOTE" | head -10
echo ""

# Step 3: Pull changes
log_step "Pulling changes..."
git stash 2>/dev/null || true
git pull origin "$BRANCH"
NEW_COMMIT=$(git rev-parse --short HEAD)
log_info "Updated to: $NEW_COMMIT"

# Step 4: Install dependencies
log_step "Installing dependencies..."
if command -v uv &> /dev/null; then
    uv sync
else
    pip3 install fastapi uvicorn psutil pydantic-settings pexpect requests colorama python-dotenv
fi
log_info "Dependencies updated"

# Step 5: Restore .env
log_step "Restoring configuration..."
if [ -f ".env.backup" ]; then
    mv .env.backup .env
    log_info "Configuration restored"
fi

# Step 6: Restart service
log_step "Restarting OV-Node service..."
systemctl restart ov-node
sleep 2

if systemctl is-active --quiet ov-node; then
    log_info "Service restarted successfully"
else
    log_error "Service failed to restart"
    echo ""
    echo "Check logs: journalctl -u ov-node -n 50"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo -e "║           ${GREEN}Update Complete!${NC}                              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "  Previous: $CURRENT_COMMIT"
echo "  Current:  $NEW_COMMIT"
echo ""
echo "Service status: $(systemctl is-active ov-node)"
echo ""
