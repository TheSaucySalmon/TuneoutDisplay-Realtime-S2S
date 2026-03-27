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
    openai_api_key: str
    openai_realtime_model: str
    openai_realtime_voice: str
    openai_realtime_instructions: str
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
    audio_profile: str
    generic_mic_device: str
    generic_speaker_device: str
    oww_model: str
    oww_threshold: float
    oww_input_device: str
    oww_cooldown_seconds: float
    oww_listen_window_seconds: float
    realtime_capture_seconds: float
    realtime_input_rate: int
    realtime_output_rate: int
    realtime_chunk_ms: int
    realtime_connect_timeout_seconds: float
    realtime_response_timeout_seconds: float

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

    @property
    def audio_profile_topic(self) -> str:
        return f"{self.base_topic}/audio/profile"

    @property
    def audio_input_topic(self) -> str:
        return f"{self.base_topic}/audio/input"

    @property
    def audio_output_topic(self) -> str:
        return f"{self.base_topic}/audio/output"

    @property
    def audio_status_topic(self) -> str:
        return f"{self.base_topic}/audio/status"

    @property
    def audio_input_ready_topic(self) -> str:
        return f"{self.base_topic}/audio/input_ready"

    @property
    def audio_output_ready_topic(self) -> str:
        return f"{self.base_topic}/audio/output_ready"

    @property
    def realtime_trigger_topic(self) -> str:
        return f"{self.base_topic}/realtime/trigger"

    @property
    def realtime_status_topic(self) -> str:
        return f"{self.base_topic}/realtime/status"

    @property
    def transcript_topic(self) -> str:
        return f"{self.base_topic}/transcript/last"

    @property
    def response_text_topic(self) -> str:
        return f"{self.base_topic}/response/last"


def load_config() -> AssistantConfig:
    state_path = Path(os.getenv("ASSISTANT_STATE_PATH", "~/.smart-display-assistant/state.json")).expanduser()
    memory_path = Path(os.getenv("ASSISTANT_MEMORY_PATH", "~/.smart-display-assistant/memory")).expanduser()
    mute_path = state_path.parent / "mute"

    return AssistantConfig(
        openai_api_key=os.getenv("OPENAI_API_KEY", "").strip(),
        openai_realtime_model=os.getenv("OPENAI_REALTIME_MODEL", "gpt-realtime").strip() or "gpt-realtime",
        openai_realtime_voice=os.getenv("OPENAI_REALTIME_VOICE", "marin").strip() or "marin",
        openai_realtime_instructions=os.getenv(
            "OPENAI_REALTIME_INSTRUCTIONS",
            "You are the household smart display assistant. Reply briefly, clearly, and helpfully.",
        ).strip()
        or "You are the household smart display assistant. Reply briefly, clearly, and helpfully.",
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
        audio_profile=os.getenv("AUDIO_PROFILE", "generic_usb").strip().lower() or "generic_usb",
        generic_mic_device=os.getenv("GENERIC_MIC_DEVICE", "").strip(),
        generic_speaker_device=os.getenv("GENERIC_SPEAKER_DEVICE", "").strip(),
        oww_model=os.getenv("OWW_MODEL", "hey_jarvis").strip() or "hey_jarvis",
        oww_threshold=float(os.getenv("OWW_THRESHOLD", "0.5")),
        oww_input_device=os.getenv("OWW_INPUT_DEVICE", "").strip(),
        oww_cooldown_seconds=float(os.getenv("OWW_COOLDOWN_SECONDS", "8")),
        oww_listen_window_seconds=float(os.getenv("OWW_LISTEN_WINDOW_SECONDS", "8")),
        realtime_capture_seconds=float(os.getenv("REALTIME_CAPTURE_SECONDS", "6")),
        realtime_input_rate=int(os.getenv("REALTIME_INPUT_RATE", "24000")),
        realtime_output_rate=int(os.getenv("REALTIME_OUTPUT_RATE", "24000")),
        realtime_chunk_ms=int(os.getenv("REALTIME_CHUNK_MS", "100")),
        realtime_connect_timeout_seconds=float(os.getenv("REALTIME_CONNECT_TIMEOUT_SECONDS", "15")),
        realtime_response_timeout_seconds=float(os.getenv("REALTIME_RESPONSE_TIMEOUT_SECONDS", "45")),
    )
