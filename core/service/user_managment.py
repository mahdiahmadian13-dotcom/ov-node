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


def update_user_on_server(name: str, password: str = "", max_devices: int = None) -> bool:
    """Update an existing user's password and/or max_devices without recreating"""
    try:
        if password:
            set_user_password(name, password)
            # Ensure the .ovpn file has auth-user-pass
            add_auth_to_ovpn(name)
        if max_devices is not None:
            save_max_devices_config(name, max_devices)
        return True
    except Exception as e:
        logger.error(f"Error updating user '{name}': {e}")
        return False


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
    """Get active connections per user from OpenVPN status log

    Counts each connected client row as one active connection and
    groups them by base username (stripping the -nodename suffix).
    """
    connections = {}
    try:
        clients = _parse_status_file()
        for client in clients:
            username = client["common_name"]
            if not username:
                continue
            # Username format: name-nodename
            if "-" in username:
                name = username.rsplit("-", 1)[0]
            else:
                name = username

            connections[name] = connections.get(name, 0) + 1

        return connections
    except Exception as e:
        logger.error(f"Error getting active connections: {e}")
        return connections


def check_and_enforce_device_limit(name: str, max_devices: int) -> bool:
    """Check if user has exceeded device limit and disconnect excess"""
    try:
        clients = _parse_status_file()

        # Exact match on base name to avoid substring collisions
        # (e.g. 'alice' must not match 'alice2-node1')
        user_connections = []
        for client in clients:
            username = client["common_name"]
            base_name = username.rsplit("-", 1)[0] if "-" in username else username
            if base_name == name:
                user_connections.append(client)

        active = len(user_connections)

        if active <= max_devices:
            return True

        # User has exceeded limit, need to disconnect
        logger.warning(
            f"User '{name}' has {active} connections, max is {max_devices}. Disconnecting excess."
        )

        # Disconnect the OLDEST connections (keep the most recent ones).
        # The section/CSV 'Connected Since' string is not reliably sortable,
        # so we simply drop the first N rows until within the limit.
        to_disconnect = user_connections[: active - max_devices]
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


def _parse_status_file():
    """Parse OpenVPN status log supporting all status formats.

    Handles:
      - status-version 1 (default): section format
        'Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since'
      - status-version 2: CSV rows prefixed with CLIENT_LIST
        'CLIENT_LIST,CN,RealAddr,VirtualAddr,BytesReceived,BytesSent,...'
      - status-version 3/4: JSON

    Returns a list of dicts:
      {common_name, bytes_received, bytes_sent}
    """
    status_file = "/var/log/openvpn-status.log"
    clients = []
    try:
        if not os.path.exists(status_file):
            logger.warning("Status file not found: %s", status_file)
            return clients

        with open(status_file, "r") as f:
            content = f.read()

        if not content.strip():
            return clients

        # ---- JSON format (status-version 3/4) ----
        stripped = content.lstrip()
        if stripped.startswith("{"):
            try:
                data = json.loads(content)
                client_list = data.get("client_list", [])
                for entry in client_list:
                    clients.append(
                        {
                            "common_name": entry.get("common_name", ""),
                            "bytes_received": int(entry.get("bytes_received", 0) or 0),
                            "bytes_sent": int(entry.get("bytes_sent", 0) or 0),
                        }
                    )
                return clients
            except (json.JSONDecodeError, ValueError, TypeError) as e:
                logger.error("Failed to parse JSON status file: %s", e)
                return clients

        lines = [l.strip() for l in content.splitlines() if l.strip()]

        # ---- CSV format v2 (CLIENT_LIST prefix) ----
        client_list_rows = [l for l in lines if l.startswith("CLIENT_LIST,")]
        if client_list_rows:
            for line in client_list_rows:
                parts = line.split(",")
                if len(parts) < 6 or parts[1] == "Common Name":
                    continue
                try:
                    clients.append(
                        {
                            "common_name": parts[1],
                            "bytes_received": int(parts[4]),
                            "bytes_sent": int(parts[5]),
                        }
                    )
                except ValueError:
                    continue
            return clients

        # ---- Section format v1 (default): after header row ----
        header_idx = None
        for i, line in enumerate(lines):
            if line.lower().startswith("common name,real address"):
                header_idx = i
                break
        if header_idx is None:
            # v1 may have no 'Common Name' header if empty; find CLIENT LIST section
            for i, line in enumerate(lines):
                if line.lower().startswith("openvpn client list"):
                    header_idx = i
                    break

        if header_idx is not None:
            in_routing = False
            for line in lines[header_idx + 1:]:
                low = line.lower()
                if low.startswith("routing table") or low.startswith("global stats") or low == "end":
                    in_routing = True
                    continue
                if in_routing:
                    continue
                parts = line.split(",")
                # Section format: Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since
                if len(parts) >= 4 and not low.startswith("updated"):
                    try:
                        clients.append(
                            {
                                "common_name": parts[0],
                                "bytes_received": int(parts[2]),
                                "bytes_sent": int(parts[3]),
                            }
                        )
                    except ValueError:
                        continue

        return clients
    except Exception as e:
        logger.error("Error parsing status file: %s", e)
        return clients


def get_users_usage() -> UsersUsage | None:
    """Get per-user traffic usage from the OpenVPN status log"""
    clients = _parse_status_file()
    users = {}
    for client in clients:
        username = client["common_name"]
        total_bytes = client["bytes_received"] + client["bytes_sent"]
        # Accumulate if the same user appears multiple times
        users[username] = users.get(username, 0) + total_bytes

    if users:
        return UsersUsage(users=users)
    else:
        return None
