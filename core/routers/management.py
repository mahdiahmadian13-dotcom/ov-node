from fastapi import APIRouter, Depends, BackgroundTasks
from core.schema.all_schemas import ResponseModel
from core.auth.auth import check_api_key
from core.logger import logger
import subprocess
import os

router = APIRouter(prefix="/sync", tags=["node_management"])


def run_script(script_path: str, args: list = None) -> dict:
    """Run a shell script and return result"""
    try:
        cmd = ["/bin/bash", script_path]
        if args:
            cmd.extend(args)

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300  # 5 minutes timeout
        )

        return {
            "success": result.returncode == 0,
            "output": result.stdout,
            "error": result.stderr if result.returncode != 0 else ""
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "output": "", "error": "Script timed out"}
    except Exception as e:
        return {"success": False, "output": "", "error": str(e)}


@router.post("/update", response_model=ResponseModel)
async def update_node(api_key: str = Depends(check_api_key)):
    """Update OV-Node from GitHub repository"""
    script_path = "/opt/ov-node/scripts/update.sh"

    if not os.path.exists(script_path):
        # Try to create the script if it doesn't exist
        try:
            import urllib.request
            url = "https://raw.githubusercontent.com/primeZdev/ov-node/main/scripts/update.sh"
            urllib.request.urlretrieve(url, script_path)
            os.chmod(script_path, 0o755)
        except Exception as e:
            return ResponseModel(
                success=False,
                msg=f"Update script not found and could not be downloaded: {str(e)}"
            )

    logger.info("Starting OV-Node update...")
    result = run_script(script_path)

    if result["success"]:
        logger.info("OV-Node updated successfully")
        return ResponseModel(
            success=True,
            msg="Update completed successfully",
            data={"output": result["output"]}
        )
    else:
        logger.error(f"Update failed: {result['error']}")
        return ResponseModel(
            success=False,
            msg=f"Update failed: {result['error']}",
            data={"output": result["output"]}
        )


@router.post("/uninstall", response_model=ResponseModel)
async def uninstall_node(
    background_tasks: BackgroundTasks,
    remove_openvpn: bool = False,
    keep_data: bool = False,
    api_key: str = Depends(check_api_key)
):
    """Uninstall OV-Node from the server"""
    script_path = "/opt/ov-node/scripts/uninstall.sh"

    if not os.path.exists(script_path):
        return ResponseModel(
            success=False,
            msg="Uninstall script not found"
        )

    # Build arguments
    args = ["--yes"]  # Skip confirmation
    if remove_openvpn:
        args.append("--remove-openvpn")
    if keep_data:
        args.append("--keep-data")

    logger.info(f"Starting OV-Node uninstall (remove_openvpn={remove_openvpn}, keep_data={keep_data})...")

    # Run uninstall in background since it will stop this service
    background_tasks.add_task(run_uninstall, script_path, args)

    return ResponseModel(
        success=True,
        msg="Uninstall started. The service will stop shortly.",
        data={"warning": "This API will become unavailable after uninstall completes."}
    )


def run_uninstall(script_path: str, args: list):
    """Run uninstall script in background"""
    try:
        subprocess.Popen(
            ["/bin/bash", script_path] + args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
    except Exception as e:
        logger.error(f"Failed to start uninstall: {e}")


@router.get("/version", response_model=ResponseModel)
async def get_version(api_key: str = Depends(check_api_key)):
    """Get current OV-Node version"""
    try:
        import git
        repo = git.Repo("/opt/ov-node")
        commit = repo.head.commit
        return ResponseModel(
            success=True,
            msg="Version retrieved",
            data={
                "commit": commit.hexsha[:7],
                "message": commit.message.strip(),
                "date": commit.committed_datetime.isoformat(),
                "branch": repo.active_branch.name
            }
        )
    except Exception as e:
        return ResponseModel(
            success=True,
            msg="Version info unavailable",
            data={"commit": "unknown", "error": str(e)}
        )


@router.get("/check-update", response_model=ResponseModel)
async def check_for_updates(api_key: str = Depends(check_api_key)):
    """Check if updates are available"""
    try:
        import git
        import urllib.request
        import json

        repo = git.Repo("/opt/ov-node")
        local_commit = repo.head.commit.hexsha

        # Fetch latest commit from GitHub API
        url = "https://api.github.com/repos/primeZdev/ov-node/commits/main"
        req = urllib.request.Request(url, headers={"User-Agent": "OV-Node"})
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read())
            remote_commit = data["sha"]

        has_update = local_commit != remote_commit

        return ResponseModel(
            success=True,
            msg="Update check completed",
            data={
                "has_update": has_update,
                "local_commit": local_commit[:7],
                "remote_commit": remote_commit[:7],
                "latest_message": data.get("commit", {}).get("message", "").strip()
            }
        )
    except Exception as e:
        return ResponseModel(
            success=False,
            msg=f"Could not check for updates: {str(e)}"
        )
