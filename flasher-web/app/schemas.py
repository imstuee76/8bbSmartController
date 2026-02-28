from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

DeviceType = Literal[
    "relay_switch",
    "light_single",
    "light_dimmer",
    "light_rgb",
    "light_rgbw",
    "fan",
]

TileType = Literal["device", "automation", "spotify", "weather"]


class DisplayConfig(BaseModel):
    resolution: str = "1920x1080"
    orientation: Literal["landscape", "portrait"] = "landscape"
    scale: float = 1.0


class SpotifyConfig(BaseModel):
    client_id: str = ""
    client_secret: str = ""
    redirect_uri: str = ""
    refresh_token: str = ""
    device_id: str = ""


class WeatherConfig(BaseModel):
    provider: str = "openweather"
    api_key: str = ""
    location: str = ""
    units: Literal["metric", "imperial"] = "metric"


class TuyaConfig(BaseModel):
    cloud_region: str = ""
    client_id: str = ""
    client_secret: str = ""
    local_scan_enabled: bool = True


class ScanConfig(BaseModel):
    subnet_hint: str = ""
    mdns_enabled: bool = True


class MoesConfig(BaseModel):
    hub_ip: str = ""
    hub_device_id: str = ""
    hub_local_key: str = ""
    hub_version: str = "3.4"
    last_discovered_at: str = ""
    last_light_scan_at: str = ""


class OTAConfig(BaseModel):
    shared_key: str = ""


class IntegrationsConfig(BaseModel):
    spotify: SpotifyConfig = Field(default_factory=SpotifyConfig)
    weather: WeatherConfig = Field(default_factory=WeatherConfig)
    tuya: TuyaConfig = Field(default_factory=TuyaConfig)
    scan: ScanConfig = Field(default_factory=ScanConfig)
    moes: MoesConfig = Field(default_factory=MoesConfig)
    ota: OTAConfig = Field(default_factory=OTAConfig)


class DeviceChannel(BaseModel):
    channel_key: str
    channel_name: str
    channel_kind: str
    payload: dict[str, Any] = Field(default_factory=dict)


class DeviceCreate(BaseModel):
    name: str
    type: DeviceType
    host: str | None = None
    mac: str | None = None
    passcode: str | None = None
    ip_mode: Literal["dhcp", "static"] = "dhcp"
    static_ip: str | None = None
    gateway: str | None = None
    subnet_mask: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    channels: list[DeviceChannel] = Field(default_factory=list)


class DeviceUpdate(BaseModel):
    name: str | None = None
    host: str | None = None
    mac: str | None = None
    passcode: str | None = None
    ip_mode: Literal["dhcp", "static"] | None = None
    static_ip: str | None = None
    gateway: str | None = None
    subnet_mask: str | None = None
    metadata: dict[str, Any] | None = None


class TileCreate(BaseModel):
    tile_type: TileType
    ref_id: str | None = None
    label: str
    payload: dict[str, Any] = Field(default_factory=dict)


class FlashJobCreate(BaseModel):
    device_id: str | None = None
    port: str
    baud: int = 921600
    firmware_filename: str


class OTASignRequest(BaseModel):
    firmware_filename: str
    version: str
    device_type: DeviceType


class DeviceCommandRequest(BaseModel):
    channel: str
    state: str | None = None
    value: int | None = None
    payload: dict[str, Any] = Field(default_factory=dict)


class DeviceOTAPushRequest(BaseModel):
    firmware_filename: str
    version: str


class FirmwareProfileCreate(BaseModel):
    profile_name: str
    firmware_filename: str
    version: str
    device_type: DeviceType
    settings: dict[str, Any] = Field(default_factory=dict)
    notes: str = ""
