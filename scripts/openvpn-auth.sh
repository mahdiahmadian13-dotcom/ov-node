#!/bin/bash
# OpenVPN auth-user-pass-verify (via-file mode)
# OpenVPN passes temp file as $1: line1=username, remaining lines=password
# NOTE: in via-file mode, $username env IS set but $password is NOT - so we
# ALWAYS read from the file when available.

PASSWORD_FILE="/etc/openvpn/passwd"
LOG="${AUTH_DEBUG_LOG:-}"  # set AUTH_DEBUG_LOG=/path to enable debugging

[ -n "$LOG" ] && echo "args=[$@]" >> $LOG

USERNAME=""
PASSWORD=""

if [ -n "$1" ] && [ -f "$1" ]; then
    USERNAME=$(head -n 1 "$1")
    PASSWORD=$(tail -n +2 "$1")
    # strip trailing newline artifacts
    PASSWORD="${PASSWORD%$'\n'}"
fi

# fallback to env (via-env mode)
if [ -z "$USERNAME" ]; then
    USERNAME="$username"
fi
if [ -z "$PASSWORD" ]; then
    PASSWORD="$password"
fi

[ -n "$LOG" ] && echo "U=[$USERNAME] P_len=[${#PASSWORD}]" >> $LOG

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    exit 1
fi

found=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
        "#"*) continue ;;
    esac
    su="${line%%:*}"
    sp="${line#*:}"
    [ -z "$su" ] && continue
    [ "$PASSWORD" = "$sp" ] || continue
    if [ "$USERNAME" = "$su" ]; then found=1; break; fi
    case "$su" in
        "$USERNAME"-*) found=1; break ;;
    esac
done < "$PASSWORD_FILE"

[ -n "$LOG" ] && echo "found=$found" >> $LOG

[ "$found" = "1" ] && exit 0
exit 1
