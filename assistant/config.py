from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class AssistantConfig:
    mqtt_host: str
    mqtt_port: int
    mqtt_username: str
    mqtt_password: str
    device_name: str
    device_id: str
    state_path: Path
    memory_path: Path
    mute_path: Path
    log_level: str
    assistant_enabled: bool

    @property
    def base_topic(self) -> str:
        return f"smart-display/{self.device_id}/assistant"

    @property
    def availability_topic(self) -> str:
        return f"{self.base_topic}/availability"

    @property
    def state_topic(self) -> str:
        return f"{self.base_topic}/state"

    @property
    def mute_state_topic(self) -> str:
        return f"{self.base_topic}/mute/state"

    @property
    def mute_command_topic(self) -> str:
        return f"{self.base_topic}/mute/set"


def load_config() -> AssistantConfig:
    state_path = Path(os.getenv("ASSISTANT_STATE_PATH", "~/.smart-display-assistant/state.json")).expanduser()
    memory_path = Path(os.getenv("ASSISTANT_MEMORY_PATH", "~/.smart-display-assistant/memory")).expanduser()
    mute_path = state_path.parent / "mute"

    return AssistantConfig(
        mqtt_host=os.getenv("MQTT_HOST", "homeassistant.local"),
        mqtt_port=int(os.getenv("MQTT_PORT", "1883")),
        mqtt_username=os.getenv("MQTT_USERNAME", ""),
        mqtt_password=os.getenv("MQTT_PASSWORD", ""),
        device_name=os.getenv("DEVICE_NAME", "Smart Display"),
        device_id=os.getenv("DEVICE_ID", os.uname().nodename.lower().replace("-", "_")),
        state_path=state_path,
        memory_path=memory_path,
        mute_path=mute_path,
        log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        assistant_enabled=_env_bool("ASSISTANT_ENABLED", True),
    )
