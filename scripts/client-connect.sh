#!/bin/bash
# OpenVPN client-connect script: device limit enforcement
# JSON keys may be stored as full CN (mahdi2-node1) or base name (mahdi2) - check both.

MAX_DEVICES_FILE="/etc/openvpn/max_devices.json"
STATUS_FILE="/var/log/openvpn-status.log"

CN="$common_name"
[ -z "$CN" ] && exit 0

if [[ "$CN" == *"-"* ]]; then
    BASE_NAME="${CN%-*}"
else
    BASE_NAME="$CN"
fi

[ -f "$MAX_DEVICES_FILE" ] || exit 0

MAX_DEVICES=$(python3 -c "
import json
try:
    with open('$MAX_DEVICES_FILE') as f:
        cfg = json.load(f)
    cn = '$CN'
    base = '$BASE_NAME'
    if cn in cfg:
        print(cfg[cn])
    elif base in cfg:
        print(cfg[base])
    else:
        print(1)
except Exception:
    print(1)
" 2>/dev/null)
[ -z "$MAX_DEVICES" ] && MAX_DEVICES=1

# Count active connections with EXACT base-name match
ACTIVE_COUNT=0
if [ -r "$STATUS_FILE" ]; then
    ACTIVE_COUNT=$(python3 -c "
lines = [l.strip() for l in open('$STATUS_FILE') if l.strip()]
csv_rows = [l for l in lines if l.startswith('CLIENT_LIST,')]
count = 0
for l in csv_rows:
    p = l.split(',')
    if len(p) > 1 and p[1] != 'Common Name':
        base = p[1].rsplit('-', 1)[0] if '-' in p[1] else p[1]
        if base == '$BASE_NAME':
            count += 1
print(count)
" 2>/dev/null)
    [ -z "$ACTIVE_COUNT" ] && ACTIVE_COUNT=0
fi

if [ "$ACTIVE_COUNT" -ge "$MAX_DEVICES" ]; then
    echo "Device limit exceeded for $BASE_NAME ($ACTIVE_COUNT/$MAX_DEVICES)" >&2
    exit 1
fi

exit 0
