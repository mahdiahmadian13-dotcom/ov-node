from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse
import psutil
from core.schema.all_schemas import User, ResponseModel, SetSettingsModel, UserConnections
from core.auth.auth import check_api_key
from core.service.user_managment import (
    create_user_on_server,
    change_user_status as change_user_status_on_server,
    delete_user_on_server,
    download_ovpn_file,
    get_users_usage,
    get_active_connections,
    get_max_devices_config,
    check_and_enforce_device_limit,
    get_user_password,
)
from core.setting.core import change_config


router = APIRouter(prefix="/sync", tags=["node_sync"])


@router.get("/status", response_model=ResponseModel)
async def get_status(request: SetSettingsModel, api_key: str = Depends(check_api_key)):
    """Get the current status of the node and set ovpn settings"""
    if request.set_new_setting:
        change_settings = change_config(request)
        if not change_settings:
            return ResponseModel(success=False, msg="Failed to change settings")

    status = {"status": "running"}
    cpu_usage = psutil.cpu_percent()
    memory_info = psutil.virtual_memory()
    status.update(
        {
            "cpu_usage": cpu_usage,
            "memory_usage": memory_info.percent,
        }
    )
    return ResponseModel(
        success=True, msg="Node status retrieved successfully", data=status
    )


@router.get("/usage", response_model=ResponseModel)
async def get_all_user_usage(api_key: str = Depends(check_api_key)):
    usages = get_users_usage()
    if usages:
        return ResponseModel(success=True, msg="Latest user usage received", data=usages)
    return ResponseModel(success=True, msg="No user is using it.")


@router.get("/connections", response_model=ResponseModel)
async def get_all_connections(api_key: str = Depends(check_api_key)):
    """Get active connections for all users"""
    connections = get_active_connections()
    result = []
    for username, count in connections.items():
        max_dev = get_max_devices_config(username)
        result.append(
            UserConnections(
                username=username,
                active_connections=count,
                max_devices=max_dev,
            ).dict()
        )
    return ResponseModel(
        success=True, msg="Connections retrieved successfully", data=result
    )


@router.get("/connections/{username}", response_model=ResponseModel)
async def get_user_connections(username: str, api_key: str = Depends(check_api_key)):
    """Get active connections for a specific user"""
    connections = get_active_connections()
    active = connections.get(username, 0)
    max_dev = get_max_devices_config(username)

    return ResponseModel(
        success=True,
        msg="User connections retrieved",
        data=UserConnections(
            username=username,
            active_connections=active,
            max_devices=max_dev,
        ).dict(),
    )


@router.post("/user", response_model=ResponseModel)
async def create_user(user: User, api_key: str = Depends(check_api_key)):
    success = create_user_on_server(user.name, user.password, user.max_devices)
    if success:
        return ResponseModel(
            success=True,
            msg="User created successfully",
            data={"client_name": user.name},
        )
    return ResponseModel(success=False, msg="Failed to create user")


@router.delete("/user/{name}", response_model=ResponseModel)
async def delete_user(name: str, api_key: str = Depends(check_api_key)):
    result = delete_user_on_server(name)
    if result:
        return ResponseModel(
            success=True,
            msg="User deleted successfully",
            data={"client_name": name},
        )
    return ResponseModel(success=False, msg="Failed to delete user")


@router.put("/user", response_model=ResponseModel)
async def change_user_status(user: User, api_key: str = Depends(check_api_key)):
    # Check device limit before allowing connection
    if user.status == "activate":
        max_dev = get_max_devices_config(user.name)
        check_and_enforce_device_limit(user.name, max_dev)

    result = change_user_status_on_server(user.name, user.status)
    if result:
        return ResponseModel(
            success=True,
            msg="User status changed successfully",
            data={"client_name": user.name},
        )
    return ResponseModel(success=False, msg="Failed to change user status")


@router.get("/download/ovpn/{client_name}")
async def download_ovpn(client_name: str, api_key: str = Depends(check_api_key)):
    response = await download_ovpn_file(client_name)
    if response:
        return FileResponse(
            path=response,
            filename=f"{client_name}.ovpn",
            media_type="application/x-openvpn-profile",
        )
    else:
        return ResponseModel(success=False, msg="OVPN file not found", data=None)
