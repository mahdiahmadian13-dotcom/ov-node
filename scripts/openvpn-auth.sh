#!/bin/bash
# OpenVPN auth-user-pass-verify script
# This script verifies username/password against /etc/openvpn/passwd
#
# To enable this script, add to /etc/openvpn/server/server.conf:
#   auth-user-pass-verify /etc/openvpn/auth.sh via-env
#   script-security 2
#
# The password file format is:
#   username:password

PASSWORD_FILE="/etc/openvpn/passwd"

# Check if password file exists
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Password file not found"
    exit 1
fi

# Get username and password from environment variables
# OpenVPN passes these via environment when using via-env
USERNAME="$username"
PASSWORD="$password"

# If not set via env, try reading from files (via-file mode)
if [ -z "$USERNAME" ] && [ -f "$1" ]; then
    USERNAME=$(head -1 "$1")
    PASSWORD=$(tail -1 "$1")
fi

# Validate inputs
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Username or password not provided"
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
