from pydantic import BaseModel
from typing import Any, Optional, Dict


class User(BaseModel):
    name: str
    password: str = ""
    max_devices: int = 1
    status: str = "activate"


class ResponseModel(BaseModel):
    success: bool
    msg: str
    data: Optional[Any] = None


class SetSettingsModel(BaseModel):
    tunnel_address: str
    protocol: str
    ovpn_port: int
    set_new_setting: bool


class UsersUsage(BaseModel):
    users: Dict[str, float]


class UserConnections(BaseModel):
    """Track active connections per user"""
    username: str
    active_connections: int
    max_devices: int
