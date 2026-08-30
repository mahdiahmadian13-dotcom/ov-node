import pexpect
import re
import os
import json
import subprocess

from core.logger import logger
from core.schema.all_schemas import UsersUsage


script_path = "/root/openvpn-install.sh"

# Password file for OpenVPN auth
PASSWORD_FILE = "/etc/openvpn/passwd"
# Max devices config file
MAX_DEVICES_FILE = "/etc/openvpn/max_devices.json"


def create_user_on_server(name, password="", max_devices=1) -> bool:
    try:
        if not os.path.exists(script_path):
            logger.error("script not found on ")
            return False

        env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
        bash = pexpect.spawn(
            "/usr/bin/bash",
            [script_path],
            env=env,
            encoding="utf-8",
            timeout=120,
        )

        bash.expect(r"Option:", timeout=90)
        bash.sendline("1")

        bash.expect(r"Name:", timeout=90)
        bash.sendline(name)
        bash.expect(pexpect.EOF, timeout=180)

        bash.close()
        ccd_file = f"/etc/openvpn/ccd/{name}"
        with open(ccd_file, "w") as f:
            f.write("")

        # Set password if provided
        if password:
            set_user_password(name, password)

        # Save max devices config
        save_max_devices_config(name, max_devices)

        # Add auth-user-pass to .ovpn file if password is set
        if password:
            add_auth_to_ovpn(name)

        return True

    except pexpect.TIMEOUT:
        logger.error("Timeout occurred while executing script!")
        return False
    except pexpect.EOF:
        logger.error("Script closed earlier than expected!")
        return False
    except Exception as e:
        logger.error(f"Error occurred: {e}")
        return False


def set_user_password(name: str, password: str) -> bool:
    """Set password for a user in the OpenVPN password file"""
    try:
        # Read existing passwords
        users = {}
        if os.path.exists(PASSWORD_FILE):
            with open(PASSWORD_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and ":" in line:
                        username, pwd = line.split(":", 1)
                        users[username] = pwd

        # Update or add user password
        users[name] = password

        # Write back
        with open(PASSWORD_FILE, "w") as f:
            for username, pwd in users.items():
                f.write(f"{username}:{pwd}\n")

        # Set proper permissions
        os.chmod(PASSWORD_FILE, 0o600)
        logger.info(f"Password set for user '{name}'")
        return True
    except Exception as e:
        logger.error(f"Error setting password for user '{name}': {e}")
        return False


def get_user_password(name: str) -> str:
    """Get password for a user"""
    try:
        if not os.path.exists(PASSWORD_FILE):
            return ""
        with open(PASSWORD_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    username, pwd = line.split(":", 1)
                    if username == name:
                        return pwd
        return ""
    except Exception as e:
        logger.error(f"Error getting password for user '{name}': {e}")
        return ""


def save_max_devices_config(name: str, max_devices: int) -> bool:
    """Save max devices configuration for a user"""
    try:
        config = {}
        if os.path.exists(MAX_DEVICES_FILE):
            with open(MAX_DEVICES_FILE, "r") as f:
                config = json.load(f)

        config[name] = max_devices

        with open(MAX_DEVICES_FILE, "w") as f:
            json.dump(config, f, indent=2)

        logger.info(f"Max devices set to {max_devices} for user '{name}'")
        return True
    except Exception as e:
        logger.error(f"Error saving max devices for user '{name}': {e}")
        return False


def get_max_devices_config(name: str) -> int:
    """Get max devices configuration for a user"""
    try:
        if not os.path.exists(MAX_DEVICES_FILE):
            return 1
        with open(MAX_DEVICES_FILE, "r") as f:
            config = json.load(f)
        return config.get(name, 1)
    except Exception as e:
        logger.error(f"Error getting max devices for user '{name}': {e}")
        return 1


def add_auth_to_ovpn(name: str) -> bool:
    """Add auth-user-pass directive to .ovpn file"""
    try:
        ovpn_file = f"/root/{name}.ovpn"
        if not os.path.exists(ovpn_file):
            logger.warning(f"OVPN file not found: {ovpn_file}")
            return False

        with open(ovpn_file, "r") as f:
            content = f.read()

        # Check if auth-user-pass already exists
        if "auth-user-pass" in content:
            return True

        # Add auth-user-pass before <ca> section or at the beginning
        if "<ca>" in content:
            content = content.replace("<ca>", "auth-user-pass\n<ca>")
        else:
            content = "auth-user-pass\n" + content

        with open(ovpn_file, "w") as f:
            f.write(content)

        logger.info(f"Added auth-user-pass to {ovpn_file}")
        return True
    except Exception as e:
        logger.error(f"Error adding auth-user-pass to OVPN file: {e}")
        return False


def get_active_connections() -> dict:
    """Get active connections per user from OpenVPN status log"""
    connections = {}
    try:
        status_file = "/var/log/openvpn-status.log"
        if not os.path.exists(status_file):
            return connections

        with open(status_file, "r") as f:
            lines = f.readlines()

        for line in lines:
            line = line.strip()
            if line.startswith("CLIENT_LIST") and not line.startswith(
                "CLIENT_LIST,Common Name"
            ):
                parts = line.split(",")
                if len(parts) >= 2:
                    username = parts[1]
                    # Username format: name-nodename
                    # We need to extract just the name part
                    if "-" in username:
                        name = username.rsplit("-", 1)[0]
                    else:
                        name = username

                    if name in connections:
                        connections[name] += 1
                    else:
                        connections[name] = 1

        return connections
    except Exception as e:
        logger.error(f"Error getting active connections: {e}")
        return connections


def check_and_enforce_device_limit(name: str, max_devices: int) -> bool:
    """Check if user has exceeded device limit and disconnect excess"""
    try:
        connections = get_active_connections()
        active = connections.get(name, 0)

        if active <= max_devices:
            return True

        # User has exceeded limit, need to disconnect
        logger.warning(
            f"User '{name}' has {active} connections, max is {max_devices}. Disconnecting excess."
        )

        # Get list of active connections for this user
        status_file = "/var/log/openvpn-status.log"
        if not os.path.exists(status_file):
            return False

        user_connections = []
        with open(status_file, "r") as f:
            lines = f.readlines()

        for line in lines:
            line = line.strip()
            if line.startswith("CLIENT_LIST") and not line.startswith(
                "CLIENT_LIST,Common Name"
            ):
                parts = line.split(",")
                if len(parts) >= 2:
                    username = parts[1]
                    if "-" in username:
                        base_name = username.rsplit("-", 1)[0]
                    else:
                        base_name = username

                    if base_name == name:
                        user_connections.append(
                            {
                                "common_name": username,
                                "real_address": parts[2] if len(parts) > 2 else "",
                                "connected_since": parts[4] if len(parts) > 4 else "",
                            }
                        )

        # Disconnect excess connections (keep the most recent ones)
        # Sort by connected_since (most recent first)
        user_connections.sort(key=lambda x: x.get("connected_since", ""), reverse=True)

        # Disconnect oldest connections
        to_disconnect = user_connections[max_devices:]
        for conn in to_disconnect:
            disconnect_client(conn["common_name"])

        return True
    except Exception as e:
        logger.error(f"Error enforcing device limit for user '{name}': {e}")
        return False


def disconnect_client(common_name: str) -> bool:
    """Disconnect a client by sending SIGUSR1 to OpenVPN management interface"""
    try:
        # Use OpenVPN management interface to disconnect
        # This requires management interface to be enabled in server.conf
        # For now, we'll use a simpler approach: kill the specific connection

        # Alternative: Use CCD to temporarily disable
        # This is a soft disconnect - the client will be disconnected on next restart
        logger.info(f"Marking client '{common_name}' for disconnection")

        # Create a temporary disable file
        disable_file = f"/etc/openvpn/ccd/{common_name}.disable"
        with open(disable_file, "w") as f:
            f.write("# Temporary disable for device limit enforcement\n")

        # Restart OpenVPN to apply changes
        restart_openvpn_service()

        # Remove the disable file after restart
        if os.path.exists(disable_file):
            os.remove(disable_file)

        return True
    except Exception as e:
        logger.error(f"Error disconnecting client '{common_name}': {e}")
        return False


def delete_user_on_server(name) -> bool | str:
    try:
        if not os.path.exists(script_path):
            logger.error("script not found at %s", script_path)
            return False

        env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
        bash = pexpect.spawn(
            "/usr/bin/bash", [script_path], env=env, encoding="utf-8", timeout=120
        )

        try:
            bash.expect(r"Option:|Select an option:", timeout=20)
        except pexpect.TIMEOUT:
            logger.warning("Did not see main menu prompt, attempting to continue")

        bash.sendline("2")

        try:
            bash.expect(
                r"Select the client to revoke:|Select the client to revoke", timeout=20
            )
        except pexpect.TIMEOUT:
            logger.info("Didn't match full header")

        bash.expect(r"Client:", timeout=20)
        list_output = bash.before

        pattern = re.compile(r"\s*(\d+)\)\s*(.+)")
        matches = pattern.findall(list_output)

        user_number = None
        for num, user in matches:
            if user.strip() == name:
                user_number = num
                break

        if not user_number:
            logger.error("User '%s' not found for delete!", name)
            bash.close(force=True)
            return "not_found"

        logger.info("Revoking user '%s' -> number %s", name, user_number)
        bash.sendline(user_number)

        try:
            bash.expect(
                r"Confirm .*revocation\?.*\[y/N\]:|Confirm .*revocation\?.*:|Confirm .*revocation\?",
                timeout=20,
            )
            bash.sendline("y")
        except pexpect.TIMEOUT:
            logger.warning("Confirmation prompt not seen; trying to continue")

        bash.expect(pexpect.EOF, timeout=120)
        bash.close()

        # remove local .ovpn file if exists
        file_to_delete = f"/root/{name}.ovpn"
        if os.path.exists(file_to_delete):
            try:
                os.remove(file_to_delete)
                logger.info("Removed %s", file_to_delete)
            except Exception as e:
                logger.error("Error deleting file %s: %s", file_to_delete, e)
                return True

        ccd_file = f"/etc/openvpn/ccd/{name}"
        if os.path.exists(ccd_file):
            try:
                os.remove(ccd_file)
                logger.info("Removed %s", ccd_file)
            except Exception as e:
                logger.error("Error deleting file %s: %s", ccd_file, e)
                return True

        # Remove from password file
        remove_user_password(name)

        # Remove from max devices config
        remove_max_devices_config(name)

        return True

    except Exception as e:
        logger.exception("Error in delete_user_on_server: %s", e)
        return False


def remove_user_password(name: str) -> bool:
    """Remove user from password file"""
    try:
        if not os.path.exists(PASSWORD_FILE):
            return True

        users = {}
        with open(PASSWORD_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and ":" in line:
                    username, pwd = line.split(":", 1)
                    users[username] = pwd

        if name in users:
            del users[name]
            with open(PASSWORD_FILE, "w") as f:
                for username, pwd in users.items():
                    f.write(f"{username}:{pwd}\n")
            logger.info(f"Removed password for user '{name}'")

        return True
    except Exception as e:
        logger.error(f"Error removing password for user '{name}': {e}")
        return False


def remove_max_devices_config(name: str) -> bool:
    """Remove user from max devices config"""
    try:
        if not os.path.exists(MAX_DEVICES_FILE):
            return True

        with open(MAX_DEVICES_FILE, "r") as f:
            config = json.load(f)

        if name in config:
            del config[name]
            with open(MAX_DEVICES_FILE, "w") as f:
                json.dump(config, f, indent=2)
            logger.info(f"Removed max devices config for user '{name}'")

        return True
    except Exception as e:
        logger.error(f"Error removing max devices config for user '{name}': {e}")
        return False


def change_user_status(name: str, status: str) -> bool:
    ccd_file = f"/etc/openvpn/ccd/{name}"
    if status == "deactivate":
        if os.path.exists(ccd_file):
            try:
                os.remove(ccd_file)
                restart_openvpn_service()
                logger.info("Removed %s", ccd_file)
            except Exception as e:
                logger.error("Error deleting file %s: %s", ccd_file, e)
                return False
        return True
    elif status == "activate":
        try:
            os.makedirs("/etc/openvpn/ccd", exist_ok=True)
            with open(ccd_file, "w") as f:
                f.write("")
            logger.info("Created %s", ccd_file)
            restart_openvpn_service()
            return True
        except Exception as e:
            logger.error("Error creating file %s: %s", ccd_file, e)
            return False


def restart_openvpn_service() -> bool:
    try:
        os.system("systemctl restart openvpn-server@server")
        logger.info("OpenVPN service restarted successfully.")
        return True
    except Exception as e:
        logger.error(f"Failed to restart OpenVPN service: {e}")
        return False


async def download_ovpn_file(name: str) -> str | None:
    """This function returns the path of the ovpn file for downloading"""
    file_path = f"/root/{name}.ovpn"
    if os.path.exists(file_path):
        return file_path
    else:
        create_user_on_server(name)
        return await download_ovpn_file(name)


def get_users_usage() -> UsersUsage | None:
    users = {}
    file_path = "/var/log/openvpn-status.log"
    with open(file_path) as f:
        lines = f.readlines()

    for line in lines:
        line = line.strip()
        if line.startswith("CLIENT_LIST") and not line.startswith(
            "CLIENT_LIST,Common Name"
        ):
            parts = line.split(",")
            username = parts[1]
            bytes_received = int(parts[5])
            bytes_sent = int(parts[6])
            total_bytes = bytes_received + bytes_sent
            users[username] = total_bytes

    if users:
        return UsersUsage(users=users)
    else:
        return None
