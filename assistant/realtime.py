from __future__ import annotations

import base64
import json
import logging
import queue
import threading
import time
from dataclasses import dataclass

from assistant.audio import GenericAudioManager
from assistant.config import AssistantConfig
from assistant.home_assistant import HomeAssistantClient

try:
    import websocket
except Exception:  # pragma: no cover - dependency installed on Pi
    websocket = None


@dataclass(frozen=True)
class RealtimeConversationResult:
    user_transcript: str
    assistant_transcript: str
    response_id: str


class OpenAIRealtimeClient:
    def __init__(self, config: AssistantConfig, audio_manager: GenericAudioManager) -> None:
        self.config = config
        self.audio_manager = audio_manager
        self.home_assistant = HomeAssistantClient(config)

    def is_available(self) -> bool:
        return bool(self.config.openai_api_key and websocket is not None)

    def run_conversation(self, *, on_state, stop_event: threading.Event | None = None) -> RealtimeConversationResult:
        if websocket is None:
            raise RuntimeError("websocket-client is not installed")
        if not self.config.openai_api_key:
            raise RuntimeError("OPENAI_API_KEY is not configured")

        stop_event = stop_event or threading.Event()
        ws = self._connect()
        player = None
        capture = None
        response_id = ""
        output_started = False
        user_transcript_parts: list[str] = []
        assistant_transcript_parts: list[str] = []

        try:
            self._send_event(ws, self._session_update_event())
            on_state("listening")

            capture = self.audio_manager.start_capture_process(self.config.realtime_input_rate)
            stdout = capture.stdout
            if stdout is None:
                raise RuntimeError("microphone capture stdout unavailable")

            chunk_bytes = max(480, int(self.config.realtime_input_rate * 2 * self.config.realtime_chunk_ms / 1000))
            capture_deadline = time.time() + self.config.realtime_capture_seconds
            while time.time() < capture_deadline and not stop_event.is_set():
                chunk = stdout.read(chunk_bytes)
                if not chunk:
                    break
                self._send_event(
                    ws,
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(chunk).decode("ascii"),
                    },
                )

            self.audio_manager.stop_process(capture, stdout)
            capture = None

            self._send_event(ws, {"type": "input_audio_buffer.commit"})
            self._send_event(ws, {"type": "response.create"})
            on_state("processing")

            player = self.audio_manager.start_playback_process(self.config.realtime_output_rate)
            player_stdin = player.stdin
            if player_stdin is None:
                raise RuntimeError("speaker playback stdin unavailable")

            deadline = time.time() + self.config.realtime_response_timeout_seconds
            while not stop_event.is_set():
                timeout = max(1, int(deadline - time.time()))
                if timeout <= 0:
                    raise TimeoutError("timed out waiting for realtime response")
                ws.settimeout(timeout)
                event = json.loads(ws.recv())
                event_type = str(event.get("type", ""))

                if event_type == "response.created":
                    response_id = str(event.get("response", {}).get("id", ""))
                    continue

                if event_type in {"response.output_audio.delta", "response.audio.delta"}:
                    if not output_started:
                        output_started = True
                        on_state("responding")
                    delta = event.get("delta", "")
                    if delta:
                        player_stdin.write(base64.b64decode(delta))
                        player_stdin.flush()
                    continue

                if event_type == "response.output_audio_transcript.delta":
                    delta = str(event.get("delta", ""))
                    if delta:
                        assistant_transcript_parts.append(delta)
                    continue

                if event_type == "conversation.item.input_audio_transcription.delta":
                    delta = str(event.get("delta", ""))
                    if delta:
                        user_transcript_parts.append(delta)
                    continue

                if event_type == "conversation.item.input_audio_transcription.completed":
                    transcript = str(event.get("transcript", "")).strip()
                    if transcript:
                        user_transcript_parts = [transcript]
                    continue

                if event_type == "response.output_audio_transcript.done":
                    transcript = str(event.get("transcript", "")).strip()
                    if transcript:
                        assistant_transcript_parts = [transcript]
                    continue

                if event_type == "response.done":
                    if self._handle_function_calls(ws, event):
                        deadline = time.time() + self.config.realtime_response_timeout_seconds
                        continue
                    break

                if event_type == "error":
                    message = event.get("error", {}).get("message") or json.dumps(event)
                    raise RuntimeError(f"realtime api error: {message}")

            return RealtimeConversationResult(
                user_transcript="".join(user_transcript_parts).strip(),
                assistant_transcript="".join(assistant_transcript_parts).strip(),
                response_id=response_id,
            )
        finally:
            if capture is not None:
                self.audio_manager.stop_process(capture, capture.stdout)
            if player is not None:
                self.audio_manager.stop_process(player, player.stdin)
            try:
                ws.close()
            except Exception:
                pass

    def _connect(self):
        url = f"wss://api.openai.com/v1/realtime?model={self.config.openai_realtime_model}"
        headers = [f"Authorization: Bearer {self.config.openai_api_key}"]
        logging.info("Connecting to OpenAI Realtime model=%s", self.config.openai_realtime_model)
        return websocket.create_connection(url, header=headers, timeout=self.config.realtime_connect_timeout_seconds)

    def _session_update_event(self) -> dict[str, object]:
        session: dict[str, object] = {
            "type": "realtime",
            "model": self.config.openai_realtime_model,
            "instructions": self._instructions(),
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "format": {
                        "type": "audio/pcm",
                        "rate": self.config.realtime_input_rate,
                    },
                    "turn_detection": None,
                },
                "output": {
                    "format": {
                        "type": "audio/pcm",
                        "rate": self.config.realtime_output_rate,
                    },
                    "voice": self.config.openai_realtime_voice,
                },
            },
        }
        tools = self._tools()
        if tools:
            session["tools"] = tools
            session["tool_choice"] = "auto"

        return {
            "type": "session.update",
            "session": session,
        }

    def _send_event(self, ws, event: dict[str, object]) -> None:
        ws.send(json.dumps(event))

    def _instructions(self) -> str:
        instructions = self.config.openai_realtime_instructions
        if not self.home_assistant.is_available():
            return instructions
        return (
            f"{instructions}\n\n"
            "You can control Home Assistant by calling the home_assistant_call_service tool. "
            "When the user asks to control a device, scene, script, automation, or helper, "
            "call the appropriate Home Assistant service. Keep spoken confirmations brief."
        )

    def _tools(self) -> list[dict[str, object]]:
        if not self.home_assistant.is_available():
            return []

        return [
            {
                "type": "function",
                "name": "home_assistant_call_service",
                "description": (
                    "Call a Home Assistant service to control devices, scenes, scripts, "
                    "automations, or helpers. Use this for lights, switches, input_booleans, "
                    "input_numbers, input_selects, covers, media players, climate, scenes, and scripts."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "domain": {
                            "type": "string",
                            "description": "Home Assistant service domain, for example light, switch, scene, input_boolean, input_number, input_select.",
                        },
                        "service": {
                            "type": "string",
                            "description": "Service name, for example turn_on, turn_off, toggle, set_value, select_option, activate.",
                        },
                        "entity_ids": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Target entity IDs, for example light.jakes_room_1 or input_boolean.movie_mode.",
                        },
                        "data": {
                            "type": "object",
                            "description": "Extra service data, such as brightness_pct, rgb_color, value, option, temperature, or transition.",
                            "additionalProperties": True,
                        },
                    },
                    "required": ["domain", "service"],
                    "additionalProperties": False,
                },
            }
        ]

    def _handle_function_calls(self, ws, event: dict[str, object]) -> bool:
        response = event.get("response", {})
        output = response.get("output", []) if isinstance(response, dict) else []
        function_calls = [
            item
            for item in output
            if isinstance(item, dict) and item.get("type") == "function_call"
        ]
        if not function_calls:
            return False

        for call in function_calls:
            call_id = str(call.get("call_id", ""))
            name = str(call.get("name", ""))
            arguments = str(call.get("arguments", "{}") or "{}")
            output_payload = self._execute_function_call(name, arguments)
            self._send_event(
                ws,
                {
                    "type": "conversation.item.create",
                    "item": {
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": json.dumps(output_payload),
                    },
                },
            )

        self._send_event(ws, {"type": "response.create"})
        return True

    def _execute_function_call(self, name: str, arguments: str) -> dict[str, object]:
        try:
            args = json.loads(arguments)
        except json.JSONDecodeError as exc:
            return {"ok": False, "message": f"Invalid tool arguments: {exc}"}

        if name != "home_assistant_call_service":
            return {"ok": False, "message": f"Unknown function: {name}"}

        entity_ids = args.get("entity_ids")
        if isinstance(entity_ids, str):
            entity_ids = [entity_ids]
        if not isinstance(entity_ids, list):
            entity_ids = None

        data = args.get("data")
        if not isinstance(data, dict):
            data = {}

        result = self.home_assistant.call_service(
            domain=str(args.get("domain", "")),
            service=str(args.get("service", "")),
            entity_ids=[str(entity) for entity in entity_ids] if entity_ids else None,
            data=data,
        )
        return {"ok": result.ok, "message": result.message, "data": result.data}


class RealtimeSessionController:
    def __init__(self, client: OpenAIRealtimeClient) -> None:
        self.client = client
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._stop_event = threading.Event()
        self._state_queue: queue.Queue[str] = queue.Queue()
        self._result_queue: queue.Queue[RealtimeConversationResult] = queue.Queue()
        self._error_queue: queue.Queue[str] = queue.Queue()

    def active(self) -> bool:
        thread = self._thread
        return thread is not None and thread.is_alive()

    def start(self) -> bool:
        with self._lock:
            if self.active():
                return False
            self._stop_event = threading.Event()
            self._thread = threading.Thread(target=self._run, name="realtime-session", daemon=True)
            self._thread.start()
            return True

    def stop(self) -> None:
        self._stop_event.set()

    def drain_states(self) -> list[str]:
        return _drain_queue(self._state_queue)

    def drain_results(self) -> list[RealtimeConversationResult]:
        return _drain_queue(self._result_queue)

    def drain_errors(self) -> list[str]:
        return _drain_queue(self._error_queue)

    def _run(self) -> None:
        try:
            result = self.client.run_conversation(on_state=self._state_queue.put, stop_event=self._stop_event)
            self._result_queue.put(result)
        except Exception as exc:
            logging.exception("Realtime session failed: %s", exc)
            self._error_queue.put(str(exc))


def _drain_queue(q: queue.Queue):
    items = []
    while True:
        try:
            items.append(q.get_nowait())
        except queue.Empty:
            return items
