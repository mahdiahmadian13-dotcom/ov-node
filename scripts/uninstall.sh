#!/bin/bash
#=============================================================
# OV-Node Uninstaller
# Completely removes OV-Node and optionally OpenVPN
#=============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OVNODE_DIR="/opt/ov-node"
OPENVPN_DIR="/etc/openvpn"
AUTH_SCRIPT="${OPENVPN_DIR}/auth.sh"
CONNECT_SCRIPT="${OPENVPN_DIR}/client-connect.sh"
PASSWORD_FILE="${OPENVPN_DIR}/passwd"
MAX_DEVICES_FILE="${OPENVPN_DIR}/max_devices.json"

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

# Parse arguments
REMOVE_OPENVPN=false
KEEP_DATA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --remove-openvpn)
            REMOVE_OPENVPN=true
            shift
            ;;
        --keep-data)
            KEEP_DATA=true
            shift
        ;;
        --yes|-y)
            # Skip confirmation
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              OV-Node Uninstaller                         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Confirmation (skip if --yes flag used)
if [[ "$1" != "--yes" ]] && [[ "$1" != "-y" ]]; then
    echo -e "${YELLOW}This will remove:${NC}"
    echo "  - OV-Node service and files"
    echo "  - Authentication scripts"
    echo "  - Password and config files"
    if [ "$REMOVE_OPENVPN" = true ]; then
        echo "  - OpenVPN server and all certificates"
    fi
    echo ""
    read -p "Are you sure? (y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""
echo "Starting uninstallation..."
echo ""

# Step 1: Stop and disable services
echo "[1/6] Stopping services..."
systemctl stop ov-node 2>/dev/null || true
systemctl disable ov-node 2>/dev/null || true
log_info "OV-Node service stopped"

if [ "$REMOVE_OPENVPN" = true ]; then
    systemctl stop openvpn-server@server 2>/dev/null || true
    systemctl disable openvpn-server@server 2>/dev/null || true
    log_info "OpenVPN service stopped"
fi

# Step 2: Remove systemd service
echo "[2/6] Removing systemd service..."
rm -f /etc/systemd/system/ov-node.service
systemctl daemon-reload
log_info "Systemd service removed"

# Step 3: Remove OV-Node files
echo "[3/6] Removing OV-Node files..."
if [ -d "$OVNODE_DIR" ]; then
    rm -rf "$OVNODE_DIR"
    log_info "OV-Node directory removed: $OVNODE_DIR"
else
    log_warn "OV-Node directory not found"
fi

# Step 4: Remove auth scripts
echo "[4/6] Removing auth scripts..."
rm -f "$AUTH_SCRIPT"
rm -f "$CONNECT_SCRIPT"
log_info "Auth scripts removed"

# Step 5: Remove data files
if [ "$KEEP_DATA" = false ]; then
    echo "[5/6] Removing data files..."
    rm -f "$PASSWORD_FILE"
    rm -f "$MAX_DEVICES_FILE"
    rm -f /var/log/openvpn-status.log
    rm -f /var/log/openvpn.log
    log_info "Data files removed"
else
    echo "[5/6] Keeping data files (--keep-data)"
fi

# Step 6: Remove OpenVPN (if requested)
if [ "$REMOVE_OPENVPN" = true ]; then
    echo "[6/6] Removing OpenVPN..."

    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt remove --purge -y openvpn easy-rsa 2>/dev/null || true
        apt autoremove -y
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        yum remove -y openvpn easy-rsa 2>/dev/null || true
    fi

    # Remove OpenVPN directory
    rm -rf "$OPENVPN_DIR"
    rm -rf /etc/openvpn

    # Remove IP forwarding config
    rm -f /etc/sysctl.d/99-openvpn.conf
    sysctl -p 2>/dev/null || true

    # Remove firewall rules (best effort)
    if command -v ufw &> /dev/null; then
        ufw delete allow 1194/udp 2>/dev/null || true
    fi

    log_info "OpenVPN removed"
else
    echo "[6/6] Keeping OpenVPN (use --remove-openvpn to remove)"
fi

# Remove install script
rm -f /root/openvpn-install.sh

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo -e "║           ${GREEN}Uninstallation Complete!${NC}                      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "Removed:"
echo "  ✓ OV-Node service"
echo "  ✓ OV-Node files"
echo "  ✓ Auth scripts"
if [ "$KEEP_DATA" = false ]; then
    echo "  ✓ Password and config files"
fi
if [ "$REMOVE_OPENVPN" = true ]; then
    echo "  ✓ OpenVPN server"
    echo "  ✓ All certificates"
fi
echo ""
