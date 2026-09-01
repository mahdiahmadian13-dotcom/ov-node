"""Cross-service connection lock: total simultaneous connections per user
across OpenVPN AND ocserv.

GET /sync/connlock/check?user=X&max=N
Counts:
  - OpenVPN online sessions (status log v2 rows)
  - ocserv online sessions (occtl -n show users)
Returns combined count + allowed bool. Both services' auth hooks call this
so a single-user plan can only hold ONE session across BOTH services.
"""
import subprocess

from fastapi import APIRouter, Depends

from core.schema.all_schemas import ResponseModel
from core.auth.auth import check_api_key

router = APIRouter(prefix="/sync/connlock", tags=["connlock"])


def _openvpn_online_users(username: str) -> int:
    try:
        lines = [l.strip() for l in open("/var/log/openvpn-status.log") if l.strip()]
        header = next((l for l in lines if l.startswith("HEADER,CLIENT_LIST")), None)
        if not header:
            return 0
        cols = header.split(",")
        # header has an extra leading "HEADER" field vs rows -> row indexes = header index - 1
        idx_user = cols.index("Username") - 1
        idx_cn = cols.index("Common Name") - 1
        count = 0
        for l in lines:
            if not l.startswith("CLIENT_LIST,"):
                continue
            parts = l.split(",")
            if len(parts) <= max(idx_user, idx_cn):
                continue
            uname = parts[idx_user]
            if uname == "UNDEF":
                uname = parts[idx_cn].split("-")[0]
            if uname == username:
                count += 1
        return count
    except Exception:
        return 0


def _ocserv_online_users(username: str) -> int:
    try:
        out = subprocess.run(["occtl", "-n", "-c", "/var/run/ocserv-socket", "show", "users"],
                             capture_output=True, text=True, timeout=8).stdout
        count = 0
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].strip(",") == username:
                count += 1
        return count
    except Exception:
        return 0


@router.get("/check", response_model=ResponseModel)
async def connlock_check(user: str, max: int, api_key: str = Depends(check_api_key)):
    """Return combined online sessions for user across both services."""
    total = _openvpn_online_users(user) + _ocserv_online_users(user)
    return ResponseModel(success=True, msg="ok",
                         data={"user": user, "online": total, "max": max,
                               "allowed": total < max})
