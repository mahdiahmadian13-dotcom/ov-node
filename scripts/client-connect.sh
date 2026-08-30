#!/bin/bash
# OpenVPN client-connect script for device limit enforcement
# This script checks if user has exceeded their device limit
#
# To enable this script, add to /etc/openvpn/server/server.conf:
#   client-connect /etc/openvpn/client-connect.sh
#   script-security 2
#
# OpenVPN passes the following environment variables:
#   common_name - the client's common name (certificate CN)
#   ifconfig_pool_remote_ip - the IP assigned to the client

MAX_DEVICES_FILE="/etc/openvpn/max_devices.json"
STATUS_FILE="/var/log/openvpn-status.log"

# Get the common name (username)
CN="$common_name"

if [ -z "$CN" ]; then
    echo "Common name not provided"
    exit 1
fi

# Extract base username (remove node suffix if present)
# Format: username-nodename
if [[ "$CN" == *"-"* ]]; then
    BASE_NAME="${CN%-*}"
else
    BASE_NAME="$CN"
fi

# Check if max devices config exists
if [ ! -f "$MAX_DEVICES_FILE" ]; then
    # No config, allow connection
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
")

# Count current active connections for this user
ACTIVE_COUNT=0
if [ -f "$STATUS_FILE" ]; then
    ACTIVE_COUNT=$(grep "^CLIENT_LIST" "$STATUS_FILE" | grep -v "^CLIENT_LIST,Common Name" | grep "$BASE_NAME" | wc -l)
fi

# Check if limit exceeded
if [ "$ACTIVE_COUNT" -ge "$MAX_DEVICES" ]; then
    echo "Device limit exceeded for user $BASE_NAME ($ACTIVE_COUNT/$MAX_DEVICES)"
    exit 1
fi

exit 0
