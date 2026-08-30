#!/bin/bash
#=============================================================
# OV-Node Auto Installer
# Installs OpenVPN + OV-Node with password auth & device limits
#=============================================================
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

OVNODE_DIR="/opt/ov-node"
OPENVPN_DIR="/etc/openvpn"
AUTH_SCRIPT="${OPENVPN_DIR}/auth.sh"
CONNECT_SCRIPT="${OPENVPN_DIR}/client-connect.sh"
PASSWORD_FILE="${OPENVPN_DIR}/passwd"
MAX_DEVICES_FILE="${OPENVPN_DIR}/max_devices.json"
STATUS_FILE="/var/log/openvpn-status.log"
REPO_URL="https://github.com/primeZdev/ov-node"

#=============================================================
# Helper Functions
#=============================================================
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           OV-Node Auto Installer v2.0                    ║"
    echo "║     OpenVPN + Password Auth + Device Limits              ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi
    log_info "Detected OS: $OS $OS_VERSION"
}

#=============================================================
# Step 1: System Update & Dependencies
#=============================================================
install_dependencies() {
    log_step "Installing system dependencies..."

    apt update -y
    apt install -y \
        python3 \
        python3-pip \
        python3-venv \
        wget \
        curl \
        git \
        unzip \
        iptables \
        net-tools \
        psmisc \
        pexpect

    log_info "Dependencies installed"
}

#=============================================================
# Step 2: Install Latest OpenVPN
#=============================================================
install_openvpn() {
    log_step "Checking OpenVPN availability..."
    # The actual OpenVPN package is installed by Nyr's script in setup_openvpn_server().
    # Here we just verify base requirements.
    apt install -y gnupg2 lsb-release >/dev/null 2>&1 || true

    if command -v openvpn &> /dev/null; then
        CURRENT_VERSION=$(openvpn --version 2>/dev/null | head -1 | awk '{print $2}')
        log_info "OpenVPN already present (version: ${CURRENT_VERSION:-unknown})"
    else
        log_info "OpenVPN will be installed by the Nyr installer in the next step"
    fi
}

#=============================================================
# Step 3: Setup OpenVPN Server (if not already configured)
#=============================================================
setup_openvpn_server() {
    log_step "Installing OpenVPN via Nyr's script (interactive automation)..."

    if [ -f "/etc/openvpn/server/server.conf" ]; then
        log_warn "OpenVPN server already configured"
        read -p "Do you want to reconfigure? This will NOT remove existing users (y/N): " RECONFIG
        if [ "$RECONFIG" != "y" ] && [ "$RECONFIG" != "Y" ]; then
            log_info "Keeping existing OpenVPN configuration"
            return
        fi
        # Nyr script handles existing installs: shows management menu. Abort here instead.
        log_info "Existing install detected - skipping fresh setup"
        return
    fi

    # Download Nyr's official script
    wget -4 -q https://git.io/vpn -O /root/openvpn-install.sh || \
        wget -4 -q https://raw.githubusercontent.com/Nyr/openvpn-install/master/openvpn-install.sh -O /root/openvpn-install.sh
    chmod +x /root/openvpn-install.sh

    # Drive the installer non-interactively with pexpect (same prompts as ov-node installer.py)
    log_info "Running Nyr installer (this takes a few minutes)..."
    python3 << 'PYEOF'
import pexpect, sys

prompts = [
    (r"Which IPv4 address should be used.*:", "1"),
    (r"Protocol.*:", "2"),          # 2 = UDP
    (r"Port.*:", "1194"),
    (r"Select a DNS server for the clients.*:", "1"),
    (r"Enter a name for the first client.*:", "first_client"),
    (r"Press any key to continue...", ""),
]

bash = pexpect.spawn("/usr/bin/bash", ["/root/openvpn-install.sh"], encoding="utf-8", timeout=300)
for pattern, reply in prompts:
    try:
        bash.expect(pattern, timeout=15)
        bash.sendline(reply)
    except pexpect.TIMEOUT:
        print(f"[warn] prompt not seen: {pattern}", file=sys.stderr)
bash.expect(pexpect.EOF, timeout=300)
bash.close()
print("Nyr installer finished")
PYEOF

    if [ ! -f "/etc/openvpn/server/server.conf" ]; then
        log_error "OpenVPN installation failed (server.conf missing)"
        exit 1
    fi

    log_info "OpenVPN server installed successfully"
}

#=============================================================
# Step 4: Setup OV-Node
#=============================================================
setup_ovnode() {
    log_step "Setting up OV-Node..."

    # Create directory
    mkdir -p "$OVNODE_DIR"

    # Clone or update repository
    if [ -d "${OVNODE_DIR}/.git" ]; then
        log_info "OV-Node already cloned, updating..."
        cd "$OVNODE_DIR"
        git pull
    else
        log_info "Cloning OV-Node repository..."
        git clone "$REPO_URL" "$OVNODE_DIR"
        cd "$OVNODE_DIR"
    fi

    # Install Python dependencies
    log_info "Installing Python dependencies..."
    if command -v uv &> /dev/null; then
        uv sync
    else
        python3 -m venv .venv
        source .venv/bin/activate
        pip install -r requirements.txt 2>/dev/null || pip install fastapi uvicorn psutil pydantic-settings pexpect requests
    fi

    # Generate API key
    API_KEY=$(openssl rand -hex 32)

    # Create .env file
    cat > "${OVNODE_DIR}/.env" << EOF
# OV-Node Configuration
SERVICE_PORT=9090
API_KEY=${API_KEY}
DEBUG=WARNING
DOC=False
EOF

    log_info "OV-Node configured"
    log_info "API Key: ${API_KEY}"
    echo ""
    log_warn "SAVE THIS API KEY! You'll need it to connect Panel to this Node."
    echo ""
}

#=============================================================
# Step 5: Setup Auth Scripts
#=============================================================
setup_auth_scripts() {
    log_step "Setting up authentication scripts..."

    # Copy auth script
    cat > "$AUTH_SCRIPT" << 'AUTHEOF'
#!/bin/bash
# OpenVPN auth-user-pass-verify script
# Verifies username/password against /etc/openvpn/passwd

PASSWORD_FILE="/etc/openvpn/passwd"

# Check if password file exists
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Password file not found" >&2
    exit 1
fi

# Get username and password from environment variables
USERNAME="$username"
PASSWORD="$password"

# If not set via env, try reading from files (via-file mode)
if [ -z "$USERNAME" ] && [ -f "$1" ]; then
    USERNAME=$(head -1 "$1")
    PASSWORD=$(tail -1 "$1")
fi

# Validate inputs
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Username or password not provided" >&2
    exit 1
fi

# Check credentials
while IFS=: read -r stored_user stored_pass; do
    if [ "$USERNAME" = "$stored_user" ] && [ "$PASSWORD" = "$stored_pass" ]; then
        exit 0
    fi
done < "$PASSWORD_FILE"

# Credentials don't match
exit 1
AUTHEOF

    chmod +x "$AUTH_SCRIPT"

    # Copy client-connect script
    cat > "$CONNECT_SCRIPT" << 'CONNECTEOF'
#!/bin/bash
# OpenVPN client-connect script for device limit enforcement
# Checks if user has exceeded their device limit

MAX_DEVICES_FILE="/etc/openvpn/max_devices.json"
STATUS_FILE="/var/log/openvpn-status.log"

# Get the common name (username)
CN="$common_name"

if [ -z "$CN" ]; then
    exit 0
fi

# Extract base username (remove node suffix if present)
if [[ "$CN" == *"-"* ]]; then
    BASE_NAME="${CN%-*}"
else
    BASE_NAME="$CN"
fi

# Check if max devices config exists
if [ ! -f "$MAX_DEVICES_FILE" ]; then
    exit 0
fi

# Get max devices for this user
MAX_DEVICES=$(python3 -c "
import json, sys
try:
    with open('$MAX_DEVICES_FILE') as f:
        config = json.load(f)
    print(config.get('$BASE_NAME', 1))
except:
    print(1)
" 2>/dev/null)

# Count current active connections for this user
ACTIVE_COUNT=0
if [ -f "$STATUS_FILE" ]; then
    ACTIVE_COUNT=$(grep "^CLIENT_LIST" "$STATUS_FILE" 2>/dev/null | grep -v "^CLIENT_LIST,Common Name" | grep "$BASE_NAME" | wc -l)
fi

# Check if limit exceeded
if [ "$ACTIVE_COUNT" -ge "$MAX_DEVICES" ]; then
    echo "Device limit exceeded for user $BASE_NAME ($ACTIVE_COUNT/$MAX_DEVICES)" >&2
    exit 1
fi

exit 0
CONNECTEOF

    chmod +x "$CONNECT_SCRIPT"

    # Initialize password file
    touch "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"

    # Initialize max devices config
    if [ ! -f "$MAX_DEVICES_FILE" ]; then
        echo '{}' > "$MAX_DEVICES_FILE"
    fi

    log_info "Auth scripts configured"
}

#=============================================================
# Step 6: Setup Systemd Service
#=============================================================
setup_systemd() {
    log_step "Setting up systemd service..."

    # Determine Python path
    if [ -f "${OVNODE_DIR}/.venv/bin/python" ]; then
        PYTHON_PATH="${OVNODE_DIR}/.venv/bin/python"
    else
        PYTHON_PATH=$(which python3)
    fi

    # Create systemd service
    cat > /etc/systemd/system/ov-node.service << EOF
[Unit]
Description=OV-Node Service
After=network.target openvpn-server@server.service
Wants=openvpn-server@server.service

[Service]
Type=simple
User=root
WorkingDirectory=${OVNODE_DIR}
Environment="PATH=/root/.local/bin:${OVNODE_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/root/.local/bin/uv run main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd
    systemctl daemon-reload

    # Enable and start service
    systemctl enable ov-node
    systemctl start ov-node

    log_info "OV-Node service configured and started"
}

#=============================================================
# Step 7: Create install.sh for OpenVPN users
#=============================================================
create_openvpn_install_script() {
    log_step "Patching OpenVPN server config for OV-Node hooks..."
    python3 << 'PYEOF'
import os

conf_path = "/etc/openvpn/server/server.conf"
with open(conf_path) as f:
    conf = f.read()

hooks = []
if "auth-user-pass-verify" not in conf:
    hooks.append("auth-user-pass-verify /etc/openvpn/auth.sh via-env")
if "client-connect /etc/openvpn/client-connect.sh" not in conf:
    hooks.append("client-connect /etc/openvpn/client-connect.sh")
if "script-security 2" not in conf:
    hooks.append("script-security 2")
if "status /var/log/openvpn-status.log" not in conf:
    hooks.append("status /var/log/openvpn-status.log 10")
if "client-config-dir" not in conf:
    hooks.append("client-config-dir /etc/openvpn/ccd")

if hooks:
    with open(conf_path, "a") as f:
        f.write("\n# OV-Node hooks\n" + "\n".join(hooks) + "\n")
    print("Added hooks:", hooks)
else:
    print("All hooks already present")
PYEOF

    # Enable ip_forward (Nyr does this too, but be safe)
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
    sysctl --system >/dev/null 2>&1 || true

    # Restart OpenVPN to load hooks
    systemctl restart openvpn-server@server 2>/dev/null || \
        systemctl restart openvpn-server 2>/dev/null || true

    log_info "OV-Node hooks installed"
}

#=============================================================
# Step 8: Verification
#=============================================================
verify_installation() {
    log_step "Verifying installation..."

    ERRORS=0

    # Check OpenVPN
    if systemctl is-active --quiet openvpn-server@server; then
        log_info "OpenVPN server is running"
    else
        log_error "OpenVPN server is not running"
        ERRORS=$((ERRORS + 1))
    fi

    # Check OV-Node
    if systemctl is-active --quiet ov-node; then
        log_info "OV-Node service is running"
    else
        log_error "OV-Node service is not running"
        ERRORS=$((ERRORS + 1))
    fi

    # Check API
    sleep 2
    if curl -s http://localhost:9090/sync/status > /dev/null 2>&1; then
        log_info "OV-Node API is responding"
    else
        log_warn "OV-Node API is not responding yet (may need a moment)"
    fi

    # Check auth script
    if [ -x "$AUTH_SCRIPT" ]; then
        log_info "Auth script is executable"
    else
        log_error "Auth script is not executable"
        ERRORS=$((ERRORS + 1))
    fi

    # Check connect script
    if [ -x "$CONNECT_SCRIPT" ]; then
        log_info "Connect script is executable"
    else
        log_error "Connect script is not executable"
        ERRORS=$((ERRORS + 1))
    fi

    # Check password file
    if [ -f "$PASSWORD_FILE" ]; then
        log_info "Password file exists"
    else
        log_error "Password file missing"
        ERRORS=$((ERRORS + 1))
    fi

    # Check max devices file
    if [ -f "$MAX_DEVICES_FILE" ]; then
        log_info "Max devices config exists"
    else
        log_error "Max devices config missing"
        ERRORS=$((ERRORS + 1))
    fi

    return $ERRORS
}

#=============================================================
# Main Installation
#=============================================================
main() {
    print_banner
    check_root
    detect_os

    echo ""
    echo -e "${YELLOW}This script will install:${NC}"
    echo "  - Latest OpenVPN server"
    echo "  - OV-Node (VPN backend manager)"
    echo "  - Password authentication"
    echo "  - Device limit enforcement"
    echo ""
    read -p "Do you want to continue? (y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Installation cancelled."
        exit 0
    fi

    echo ""
    log_step "Starting installation..."
    echo ""

    install_dependencies
    echo ""

    install_openvpn
    echo ""

    setup_openvpn_server
    echo ""

    setup_ovnode
    echo ""

    setup_auth_scripts
    echo ""

    create_openvpn_install_script
    echo ""

    setup_systemd
    echo ""

    verify_installation
    RESULT=$?

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    if [ $RESULT -eq 0 ]; then
        echo -e "║           ${GREEN}Installation Complete!${NC}                         ║"
    else
        echo -e "║           ${YELLOW}Installation Complete with warnings${NC}             ║"
    fi
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    # Read API key from .env
    API_KEY=$(grep API_KEY "${OVNODE_DIR}/.env" | cut -d'=' -f2)

    echo -e "${CYAN}Connection Information:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Node Address:  ${GREEN}$(curl -s ifconfig.me):9090${NC}"
    echo -e "  API Key:       ${GREEN}${API_KEY}${NC}"
    echo -e "  OpenVPN Port:  ${GREEN}1194/udp${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Add this Node to your OV-Panel"
    echo "  2. Use the API Key above to connect"
    echo "  3. Start creating users with password protection!"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  systemctl status ov-node      # Check OV-Node status"
    echo "  systemctl status openvpn-server@server  # Check OpenVPN status"
    echo "  journalctl -u ov-node -f      # View OV-Node logs"
    echo "  cat /var/log/openvpn.log      # View OpenVPN logs"
    echo ""
}

# Run main function
main "$@"
