#!/bin/bash
# TEMPORARY DEBUG script - captures what OpenVPN actually passes
echo "=== $(date) ===" >> /tmp/auth-debug.log
echo "all env:" >> /tmp/auth-debug.log
env | sort >> /tmp/auth-debug.log
echo "--- args: $@ ---" >> /tmp/auth-debug.log
echo "username=[$username] password=[$password] common_name=[$common_name]" >> /tmp/auth-debug.log
echo "" >> /tmp/auth-debug.log

# Then behave EXACTLY like the real auth script (base-name match + full match)
PASSWORD_FILE="/etc/openvpn/passwd"

USERNAME="$username"
PASSWORD="$password"

if [ -z "$USERNAME" ] && [ -f "$1" ]; then
    USERNAME=$(head -1 "$1")
    PASSWORD=$(tail -1 "$1")
fi

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "DEBUG: empty username or password" >> /tmp/auth-debug.log
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

    [ "$PASSWORD" = "$stored_pass" ] || continue

    if [ "$USERNAME" = "$stored_user" ]; then
        found=1
        break
    fi

    case "$stored_user" in
        "$USERNAME"-*)
            found=1
            break
            ;;
    esac
done < "$PASSWORD_FILE"

echo "DEBUG: username=[$USERNAME] found=$found" >> /tmp/auth-debug.log

if [ "$found" = "1" ]; then
    exit 0
fi
exit 1
