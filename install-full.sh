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
    log_step "Installing latest OpenVPN..."

    # Check if OpenVPN is already installed
    if command -v openvpn &> /dev/null; then
        CURRENT_VERSION=$(openvpn --version | head -1 | awk '{print $2}')
        log_warn "OpenVPN already installed (version: $CURRENT_VERSION)"
        read -p "Do you want to reinstall/update? (y/N): " REINSTALL
        if [ "$REINSTALL" != "y" ] && [ "$REINSTALL" != "Y" ]; then
            log_info "Skipping OpenVPN installation"
            return
        fi
    fi

    # Install from official OpenVPN repository
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        # Add OpenVPN repository
        apt install -y gnupg2

        # Get Ubuntu codename
        if [ "$OS" = "ubuntu" ]; then
            CODENAME=$(lsb_release -cs)
        else
            CODENAME="bookworm"
        fi

        # Add OpenVPN APT repository
        wget -O - https://packages.openvpn.net/packages-repo.gpg.key | apt-key add -
        echo "deb http://packages.openvpn.net/packages/apt $CODENAME main" > /etc/apt/sources.list.d/openvpn.list

        apt update -y
        apt install -y openvpn easy-rsa

    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        yum install -y epel-release
        yum install -y openvpn easy-rsa

    else
        log_error "Unsupported OS: $OS"
        exit 1
    fi

    # Verify installation
    if command -v openvpn &> /dev/null; then
        NEW_VERSION=$(openvpn --version | head -1 | awk '{print $2}')
        log_info "OpenVPN installed successfully (version: $NEW_VERSION)"
    else
        log_error "OpenVPN installation failed"
        exit 1
    fi
}

#=============================================================
# Step 3: Setup OpenVPN Server (if not already configured)
#=============================================================
setup_openvpn_server() {
    log_step "Setting up OpenVPN server..."

    # Check if server is already configured
    if [ -f "${OPENVPN_DIR}/server/server.conf" ]; then
        log_warn "OpenVPN server already configured"
        read -p "Do you want to reconfigure? (y/N): " RECONFIG
        if [ "$RECONFIG" != "y" ] && [ "$RECONFIG" != "Y" ]; then
            log_info "Skipping server configuration"
            return
        fi
    fi

    # Use easy-rsa to setup PKI
    EASYRSA_DIR="/etc/openvpn/easy-rsa"

    if [ ! -d "$EASYRSA_DIR" ]; then
        make-cadir "$EASYRSA_DIR"
    fi

    cd "$EASYRSA_DIR"

    # Initialize PKI
    ./easyrsa --batch init-pki

    # Build CA (non-interactive)
    ./easyrsa --batch build-ca nopass

    # Generate server certificate
    ./easyrsa --batch build-server-full server nopass

    # Generate Diffie-Hellman parameters
    ./easyrsa --batch gen-dh

    # Generate TLS auth key
    openvpn --genkey secret /etc/openvpn/ta.key

    # Copy certificates
    cp pki/ca.crt /etc/openvpn/server/
    cp pki/issued/server.crt /etc/openvpn/server/
    cp pki/private/server.key /etc/openvpn/server/
    cp pki/dh.pem /etc/openvpn/server/

    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')

    # Create server configuration
    cat > /etc/openvpn/server/server.conf << EOF
# OpenVPN Server Configuration
port 1194
proto udp
dev tun

# Certificates
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh /etc/openvpn/server/dh.pem
tls-auth /etc/openvpn/ta.key 0

# Network
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt

# Push routes
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

# Security
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384

# Performance
keepalive 10 120
compress lz4-v2
push "compress lz4-v2"

# Permissions
persist-key
persist-tun
user nobody
group nogroup

# Logging
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
mute 20
max-clients 100

# Client Configuration Directory
client-config-dir /etc/openvpn/ccd

# Password Authentication (OV-Node)
auth-user-pass-verify /etc/openvpn/auth.sh via-env
script-security 2

# Device Limit Enforcement (OV-Node)
client-connect /etc/openvpn/client-connect.sh
script-security 2
EOF

    # Create CCD directory
    mkdir -p /etc/openvpn/ccd

    # Create log directory
    mkdir -p /var/log/openvpn

    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-openvpn.conf
    sysctl -p /etc/sysctl.d/99-openvpn.conf

    # Configure firewall
    if command -v ufw &> /dev/null; then
        # UFW
        ufw allow 1194/udp
        ufw allow 22/tcp
        # Add NAT rules
        sed -i '/COMMIT/i -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE' /etc/ufw/before.rules
        ufw reload
    else
        # iptables
        iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
        iptables -A INPUT -i tun0 -j ACCEPT
        iptables -A FORWARD -i tun0 -j ACCEPT
        iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i eth0 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
        # Save rules
        iptables-save > /etc/iptables.rules
    fi

    # Enable OpenVPN service
    systemctl enable openvpn-server@server
    systemctl start openvpn-server@server

    log_info "OpenVPN server configured successfully"
    log_info "Server IP: $SERVER_IP"
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
Environment="PATH=${OVNODE_DIR}/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${PYTHON_PATH} -m uvicorn main:app --host 0.0.0.0 --port 9090
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
    log_step "Creating OpenVPN user install script..."

    cat > /root/openvpn-install.sh << 'INSTALLEOF'
#!/bin/bash
# OpenVPN User Management Script
# Used by OV-Node to create/delete users

case "$1" in
    add|1)
        # Add new user
        if [ -z "$2" ]; then
            echo "Usage: $0 add <username>"
            exit 1
        fi
        USERNAME="$2"

        # Generate client certificate
        cd /etc/openvpn/easy-rsa
        ./easyrsa --batch build-client-full "$USERNAME" nopass

        # Create .ovpn file
        cat > "/root/${USERNAME}.ovpn" << EOF
client
dev tun
proto udp
remote $(curl -s ifconfig.me) 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
key-direction 1
verb 3

<ca>
$(cat /etc/openvpn/server/ca.crt)
</ca>
<cert>
$(openssl x509 -in /etc/openvpn/easy-rsa/pki/issued/${USERNAME}.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/${USERNAME}.key)
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

        echo "User $USERNAME created successfully"
        echo "1" # Option number for pexpect
        ;;

    revoke|2)
        # Revoke user
        if [ -z "$2" ]; then
            # List users and let caller select
            echo "Select the client to revoke:"
            cd /etc/openvpn/easy-rsa
            INDEX=1
            for cert in pki/issued/*.crt; do
                NAME=$(basename "$cert" .crt)
                if [ "$NAME" != "server" ]; then
                    echo "$INDEX) $NAME"
                    INDEX=$((INDEX + 1))
                fi
            done
            echo "Client:"
            read -r SELECTION
            # Process selection...
        else
            USERNAME="$2"
            cd /etc/openvpn/easy-rsa
            ./easyrsa --batch revoke "$USERNAME"
            ./easyrsa --batch gen-crl
            cp pki/crl.pem /etc/openvpn/server/
            rm -f "/root/${USERNAME}.ovpn"
            rm -f "/etc/openvpn/ccd/${USERNAME}"
            echo "User $USERNAME revoked successfully"
        fi
        ;;

    *)
        echo "Usage: $0 {add|revoke} [username]"
        exit 1
        ;;
esac
INSTALLEOF

    chmod +x /root/openvpn-install.sh
    log_info "OpenVPN install script created"
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
