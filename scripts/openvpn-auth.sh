#!/bin/bash
# OpenVPN auth-user-pass-verify script
# Verifies username/password against /etc/openvpn/passwd
#
# Accepts BOTH:
#   - full node username:  ali-hosdtvds1
#   - base username:       ali  (matches ali-*)
#
# Password file format:  username:password  (password may contain ':')

PASSWORD_FILE="/etc/openvpn/passwd"

if [ ! -f "$PASSWORD_FILE" ]; then
    exit 1
fi

USERNAME="$username"
PASSWORD="$password"

# via-file fallback
if [ -z "$USERNAME" ] && [ -f "$1" ]; then
    USERNAME=$(head -1 "$1")
    PASSWORD=$(tail -1 "$1")
fi

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    exit 1
fi

found=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac
    stored_user="${line%%:*}"
    stored_pass="${line#*:}"
    [ -z "$stored_user" ] && continue

    # password must match first
    [ "$PASSWORD" = "$stored_pass" ] || continue

    # exact match (client typed full name incl. node suffix)
    if [ "$USERNAME" = "$stored_user" ]; then
        found=1
        break
    fi

    # base-name match (client typed name without -nodesuffix)
    case "$stored_user" in
        "$USERNAME"-*)
            found=1
            break
            ;;
    esac
done < "$PASSWORD_FILE"

if [ "$found" = "1" ]; then
    exit 0
fi

exit 1
