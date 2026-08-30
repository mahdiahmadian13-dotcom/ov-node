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
    exit 0
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

# Get max devices for this user (exact key match)
MAX_DEVICES=$(python3 -c "
import json
try:
    with open('$MAX_DEVICES_FILE') as f:
        config = json.load(f)
    print(config.get('$BASE_NAME', 1))
except Exception:
    print(1)
" 2>/dev/null)

if [ -z "$MAX_DEVICES" ]; then
    MAX_DEVICES=1
fi

# Count current active connections for this user.
# The status log may be in section format (default, status-version 1) or
# CLIENT_LIST CSV format (status-version 2). Count the client rows in both.
ACTIVE_COUNT=0
if [ -f "$STATUS_FILE" ]; then
    ACTIVE_COUNT=$(python3 -c "
import sys

cn = '$CN'
base = '$BASE_NAME'
count = 0
try:
    with open('$STATUS_FILE') as f:
        lines = [l.strip() for l in f if l.strip()]

    # v2 CSV format: rows prefixed with CLIENT_LIST
    csv_rows = [l for l in lines if l.startswith('CLIENT_LIST,')]
    if csv_rows:
        for l in csv_rows:
            parts = l.split(',')
            if len(parts) > 1 and parts[1] != 'Common Name':
                row_base = parts[1].rsplit('-', 1)[0] if '-' in parts[1] else parts[1]
                if row_base == base:
                    count += 1
    else:
        # v1 section format: rows after 'Common Name,Real Address,...' header
        try:
            idx = next(i for i, l in enumerate(lines) if l.lower().startswith('common name,real address'))
        except StopIteration:
            try:
                idx = next(i for i, l in enumerate(lines) if l.lower().startswith('openvpn client list'))
            except StopIteration:
                idx = -1
        if idx != -1:
            in_routing = False
            for l in lines[idx+1:]:
                low = l.lower()
                if low.startswith('routing table') or low.startswith('global stats') or low == 'end':
                    in_routing = True
                    continue
                if in_routing:
                    continue
                parts = l.split(',')
                if len(parts) >= 1 and not low.startswith('updated'):
                    row_base = parts[0].rsplit('-', 1)[0] if '-' in parts[0] else parts[0]
                    if row_base == base:
                        count += 1
except Exception:
    pass
print(count)
" 2>/dev/null)
fi

if [ -z "$ACTIVE_COUNT" ]; then
    ACTIVE_COUNT=0
fi

# Check if limit exceeded (current active already includes? No - client-connect
# runs BEFORE this client is added to the status log, so compare >= max)
if [ "$ACTIVE_COUNT" -ge "$MAX_DEVICES" ]; then
    echo "Device limit exceeded for user $BASE_NAME ($ACTIVE_COUNT/$MAX_DEVICES)" >&2
    exit 1
fi

exit 0
