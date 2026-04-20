#!/usr/bin/env python3
from __future__ import annotations

import json
import logging
import math
import struct
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import paho.mqtt.client as mqtt

from assistant.audio import AudioStatus, GenericAudioManager
from assistant.config import AssistantConfig, load_config
from assistant.realtime import OpenAIRealtimeClient, RealtimeConversationResult, RealtimeSessionController
from assistant.state import AssistantStateStore
from assistant.wakeword import OpenWakeWordDetector


class AssistantRuntimeService:
    def __init__(self, config: AssistantConfig) -> None:
        self.config = config
        self.state_store = AssistantStateStore(config.state_path, config.mute_path)
        self.audio_manager = GenericAudioManager(config)
        self.wakeword_detector = OpenWakeWordDetector(config, self.audio_manager)
        self.realtime_client = OpenAIRealtimeClient(config, self.audio_manager)
        self.realtime_session = RealtimeSessionController(self.realtime_client)
        self._audio_status: AudioStatus | None = None
        self._last_audio_probe = 0.0
        self._realtime_status = "idle"
        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"smart-display-assistant-{config.device_id}",
        )
        if config.mqtt_username:
            self.client.username_pw_set(config.mqtt_username, config.mqtt_password)

        self.client.on_connect = self.on_connect
        self.client.on_message = self.on_message
        self.client.on_disconnect = self.on_disconnect
        self.client.will_set(config.availability_topic, "offline", retain=True)
        self.client.reconnect_delay_set(min_delay=1, max_delay=30)
        self._stop_event = threading.Event()

    def discovery_topics(self) -> list[tuple[str, dict[str, object]]]:
        device = {
            "identifiers": [self.config.device_id],
            "name": self.config.device_name,
            "model": "Smart Display Assistant",
            "manufacturer": "DIY",
            "sw_version": "0.1",
        }
        return [
            (
                f"homeassistant/button/{self.config.device_id}/assistant_trigger/config",
                {
                    "name": "Assistant Trigger",
                    "unique_id": f"{self.config.device_id}_assistant_trigger",
                    "device": device,
                    "command_topic": self.config.realtime_trigger_topic,
                    "payload_press": "PRESS",
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:microphone-message",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_realtime_status/config",
                {
                    "name": "Assistant Realtime Status",
                    "unique_id": f"{self.config.device_id}_assistant_realtime_status",
                    "device": device,
                    "state_topic": self.config.realtime_status_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:websocket",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_last_transcript/config",
                {
                    "name": "Assistant Last Transcript",
                    "unique_id": f"{self.config.device_id}_assistant_last_transcript",
                    "device": device,
                    "state_topic": self.config.transcript_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:account-voice",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_last_response/config",
                {
                    "name": "Assistant Last Response",
                    "unique_id": f"{self.config.device_id}_assistant_last_response",
                    "device": device,
                    "state_topic": self.config.response_text_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:message-reply-text",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_state/config",
                {
                    "name": "Assistant State",
                    "unique_id": f"{self.config.device_id}_assistant_state",
                    "device": device,
                    "state_topic": self.config.state_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:robot-outline",
                },
            ),
            (
                f"homeassistant/switch/{self.config.device_id}/mute/config",
                {
                    "name": "Mute",
                    "unique_id": f"{self.config.device_id}_mute",
                    "device": device,
                    "state_topic": self.config.mute_state_topic,
                    "command_topic": self.config.mute_command_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "payload_on": "ON",
                    "payload_off": "OFF",
                    "state_on": "ON",
                    "state_off": "OFF",
                    "icon": "mdi:microphone-off",
                },
            ),
            (
                f"homeassistant/binary_sensor/{self.config.device_id}/assistant_online/config",
                {
                    "name": "Assistant Online",
                    "unique_id": f"{self.config.device_id}_assistant_online",
                    "device": device,
                    "state_topic": self.config.availability_topic,
                    "payload_on": "online",
                    "payload_off": "offline",
                    "device_class": "connectivity",
                    "icon": "mdi:lan-connect",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_audio_profile/config",
                {
                    "name": "Assistant Audio Profile",
                    "unique_id": f"{self.config.device_id}_assistant_audio_profile",
                    "device": device,
                    "state_topic": self.config.audio_profile_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:tune-vertical",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_audio_input/config",
                {
                    "name": "Assistant Audio Input",
                    "unique_id": f"{self.config.device_id}_assistant_audio_input",
                    "device": device,
                    "state_topic": self.config.audio_input_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:microphone",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_audio_output/config",
                {
                    "name": "Assistant Audio Output",
                    "unique_id": f"{self.config.device_id}_assistant_audio_output",
                    "device": device,
                    "state_topic": self.config.audio_output_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:speaker",
                },
            ),
            (
                f"homeassistant/sensor/{self.config.device_id}/assistant_audio_status/config",
                {
                    "name": "Assistant Audio Status",
                    "unique_id": f"{self.config.device_id}_assistant_audio_status",
                    "device": device,
                    "state_topic": self.config.audio_status_topic,
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "icon": "mdi:information-outline",
                },
            ),
            (
                f"homeassistant/binary_sensor/{self.config.device_id}/assistant_audio_input_ready/config",
                {
                    "name": "Assistant Audio Input Ready",
                    "unique_id": f"{self.config.device_id}_assistant_audio_input_ready",
                    "device": device,
                    "state_topic": self.config.audio_input_ready_topic,
                    "payload_on": "ON",
                    "payload_off": "OFF",
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "device_class": "connectivity",
                    "icon": "mdi:microphone-check",
                },
            ),
            (
                f"homeassistant/binary_sensor/{self.config.device_id}/assistant_audio_output_ready/config",
                {
                    "name": "Assistant Audio Output Ready",
                    "unique_id": f"{self.config.device_id}_assistant_audio_output_ready",
                    "device": device,
                    "state_topic": self.config.audio_output_ready_topic,
                    "payload_on": "ON",
                    "payload_off": "OFF",
                    "availability_topic": self.config.availability_topic,
                    "payload_available": "online",
                    "payload_not_available": "offline",
                    "device_class": "connectivity",
                    "icon": "mdi:speaker-wireless",
                },
            ),
        ]

    def publish_state(self) -> None:
        state = self.state_store.current_state()
        muted = self.state_store.is_muted()
        self.client.publish(self.config.state_topic, state, retain=True)
        self.client.publish(self.config.mute_state_topic, "ON" if muted else "OFF", retain=True)
        self.client.publish(self.config.realtime_status_topic, self._realtime_status, retain=True)

    def publish_audio_status(self, status: AudioStatus) -> None:
        self.client.publish(self.config.audio_profile_topic, status.profile, retain=True)
        self.client.publish(self.config.audio_input_topic, status.input_device, retain=True)
        self.client.publish(self.config.audio_output_topic, status.output_device, retain=True)
        self.client.publish(self.config.audio_status_topic, status.details, retain=True)
        self.client.publish(self.config.audio_input_ready_topic, "ON" if status.input_ready else "OFF", retain=True)
        self.client.publish(self.config.audio_output_ready_topic, "ON" if status.output_ready else "OFF", retain=True)

    def refresh_audio_status(self, force: bool = False) -> AudioStatus | None:
        now = time.time()
        if not force and (now - self._last_audio_probe) < 30 and self._audio_status is not None:
            return self._audio_status

        status = self.audio_manager.probe()
        self._audio_status = status
        self._last_audio_probe = now
        self.publish_audio_status(status)
        logging.info(
            "Audio profile=%s input=%s output=%s details=%s",
            status.profile,
            status.input_device,
            status.output_device,
            status.details,
        )
        return status

    def on_connect(self, client, userdata, connect_flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            logging.warning("MQTT connection failed: %s", reason_code)
            return

        logging.info("Connected to MQTT broker %s:%s", self.config.mqtt_host, self.config.mqtt_port)
        client.publish(self.config.availability_topic, "online", retain=True)
        for topic, payload in self.discovery_topics():
            client.publish(topic, json.dumps(payload), retain=True)
        client.subscribe(self.config.mute_command_topic)
        client.subscribe(self.config.realtime_trigger_topic)
        self.publish_state()
        self.refresh_audio_status(force=True)

    def on_message(self, client, userdata, msg) -> None:
        if msg.topic == self.config.realtime_trigger_topic:
            payload = msg.payload.decode("utf-8", errors="replace").strip().upper()
            if payload in {"", "PRESS", "ON", "START", "TRIGGER"}:
                self._start_realtime_session("manual")
            return

        if msg.topic != self.config.mute_command_topic:
            return

        payload = msg.payload.decode("utf-8", errors="replace").strip().upper()
        muted = payload in {"ON", "1", "TRUE"}
        self.state_store.set_muted(muted)
        if muted:
            self.realtime_session.stop()
        self.publish_state()
        logging.info("Mute set to %s", muted)

    def on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties) -> None:
        if reason_code.is_failure:
            logging.warning("Unexpected MQTT disconnect: %s", reason_code)

    def run(self) -> None:
        self.config.memory_path.mkdir(parents=True, exist_ok=True)
        self.client.connect_async(self.config.mqtt_host, self.config.mqtt_port, keepalive=60)
        self.client.loop_start()
        logging.info("Assistant runtime service started.")
        logging.info("State path: %s", self.config.state_path)
        logging.info("Memory path: %s", self.config.memory_path)
        logging.info("Audio profile: %s", self.config.audio_profile)
        logging.info(
            "OWW model=%s threshold=%.2f",
            self.config.oww_model,
            self.config.oww_threshold,
        )
        logging.info(
            "Realtime model=%s voice=%s",
            self.config.openai_realtime_model,
            self.config.openai_realtime_voice,
        )

        if not self.config.assistant_enabled:
            logging.warning("ASSISTANT_ENABLED is false; service will stay idle but online.")
        else:
            self._start_wakeword_detector()

        try:
            while not self._stop_event.wait(1):
                status = self.refresh_audio_status()
                self._drain_realtime_updates()
                if self.state_store.is_muted():
                    continue

                if status and not status.input_ready:
                    if self.state_store.current_state() != "error":
                        self.state_store.set_state("error")
                        self.publish_state()
                    continue

                if not self.realtime_client.is_available():
                    if not self.config.openai_api_key:
                        self._realtime_status = "api-key-missing"
                    else:
                        self._realtime_status = "websocket-client-missing"
                    self.publish_state()
                    continue

                if self.realtime_session.active():
                    continue

                self._ensure_wakeword_detector()
                event = self.wakeword_detector.poll()
                if event is not None:
                    self._start_realtime_session("wakeword")
                    continue

                if self.state_store.current_state() != "idle":
                    self.state_store.set_state("idle")
                    self.publish_state()
        finally:
            self.shutdown()

    def shutdown(self) -> None:
        if self._stop_event.is_set():
            return
        self._stop_event.set()
        logging.info("Assistant runtime service stopping.")
        with suppress(Exception):
            self.realtime_session.stop()
        with suppress(Exception):
            self._stop_wakeword_detector()
        with suppress(Exception):
            self.client.publish(self.config.availability_topic, "offline", retain=True)
        with suppress(Exception):
            self.client.loop_stop()
        with suppress(Exception):
            self.client.disconnect()

    def _start_realtime_session(self, reason: str) -> None:
        if self.state_store.is_muted():
            logging.info("Ignoring %s trigger while muted.", reason)
            return

        if not self.realtime_client.is_available():
            if not self.config.openai_api_key:
                self._realtime_status = "api-key-missing"
            else:
                self._realtime_status = "websocket-client-missing"
            self.publish_state()
            logging.warning("Ignoring %s trigger because Realtime is unavailable: %s", reason, self._realtime_status)
            return

        status = self.refresh_audio_status()
        if status and (not status.input_ready or not status.output_ready):
            self.state_store.set_state("error")
            self._realtime_status = "audio-unavailable"
            self.publish_state()
            return

        if reason == "wakeword":
            self._stop_wakeword_detector()
            self._play_wake_ack()

        started = self.realtime_session.start()
        if not started:
            logging.info("Realtime session already active; ignoring %s trigger.", reason)
            if reason == "wakeword":
                self._start_wakeword_detector()
            return

        if reason != "wakeword":
            self._stop_wakeword_detector()
        self._realtime_status = f"starting:{reason}"
        self.state_store.set_state("listening")
        self.publish_state()
        logging.info("Realtime session started by %s trigger.", reason)

    def _drain_realtime_updates(self) -> None:
        dirty = False
        for state in self.realtime_session.drain_states():
            self._realtime_status = state
            self.state_store.set_state(state)
            dirty = True

        for result in self.realtime_session.drain_results():
            self._handle_realtime_result(result)
            self._realtime_status = "idle"
            self.state_store.set_state("idle")
            self._start_wakeword_detector()
            dirty = True

        errors = self.realtime_session.drain_errors()
        if errors:
            self._realtime_status = f"error:{errors[-1]}"
            self.state_store.set_state("error")
            self._start_wakeword_detector()
            dirty = True

        if dirty:
            self.publish_state()

    def _handle_realtime_result(self, result: RealtimeConversationResult) -> None:
        if result.user_transcript:
            self.client.publish(self.config.transcript_topic, result.user_transcript, retain=True)
        if result.assistant_transcript:
            self.client.publish(self.config.response_text_topic, result.assistant_transcript, retain=True)

    def _start_wakeword_detector(self) -> None:
        if not self.config.assistant_enabled or self.state_store.is_muted() or self.realtime_session.active():
            return
        self.wakeword_detector.start()
        logging.info("OWW status: %s", self.wakeword_detector.status)

    def _ensure_wakeword_detector(self) -> None:
        if self.wakeword_detector.active():
            return
        self._start_wakeword_detector()

    def _stop_wakeword_detector(self) -> None:
        self.wakeword_detector.stop()
        logging.info("OWW detector stopped.")

    def _play_wake_ack(self) -> None:
        mode = self.config.wake_ack_mode
        if mode in {"", "off", "none", "false", "0"}:
            return

        try:
            if mode == "file" and self.config.wake_ack_file:
                self._play_wake_ack_file(self.config.wake_ack_file)
                return
            self._play_wake_ack_tone()
        except Exception as exc:
            logging.warning("Wake acknowledgement failed: %s", exc)

    def _play_wake_ack_file(self, path: str) -> None:
        ack_path = Path(path).expanduser()
        if not ack_path.exists():
            logging.warning("Wake acknowledgement file not found: %s", ack_path)
            return

        command = ["aplay", "-q", "-D", self.audio_manager.playback_device(), str(ack_path)]
        logging.info("Playing wake acknowledgement file: %s", ack_path)
        subprocess.run(command, check=False, timeout=3)

    def _play_wake_ack_tone(self) -> None:
        sample_rate = 24_000
        duration_seconds = 0.12
        frequency_hz = 740
        volume = 0.18
        sample_count = int(sample_rate * duration_seconds)
        pcm = bytearray()
        for index in range(sample_count):
            fade = min(index / 240, (sample_count - index) / 240, 1.0)
            sample = int(math.sin(2 * math.pi * frequency_hz * index / sample_rate) * 32767 * volume * fade)
            pcm.extend(struct.pack("<h", sample))

        command = [
            "aplay",
            "-q",
            "-D",
            self.audio_manager.playback_device(),
            "-r",
            str(sample_rate),
            "-f",
            "S16_LE",
            "-c",
            "1",
            "-t",
            "raw",
        ]
        logging.info("Playing wake acknowledgement tone.")
        subprocess.run(command, input=bytes(pcm), check=False, timeout=3)


class suppress:
    def __init__(self, *exceptions):
        self.exceptions = exceptions or (Exception,)

    def __enter__(self):
        return None

    def __exit__(self, exc_type, exc, tb):
        return exc_type is not None and issubclass(exc_type, self.exceptions)


def main() -> int:
    config = load_config()
    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="[assistant] %(levelname)s: %(message)s",
    )
    service = AssistantRuntimeService(config)

    def _handle_signal(signum, frame) -> None:
        logging.info("Received signal %s", signum)
        service.shutdown()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    try:
        service.run()
    except Exception as exc:  # pragma: no cover - startup failure path
        logging.exception("Assistant runtime failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
