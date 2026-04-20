from __future__ import annotations

import logging
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from assistant.audio import GenericAudioManager
from assistant.config import AssistantConfig

try:
    import numpy as np
except Exception:  # pragma: no cover - optional dependency path
    np = None

try:
    from openwakeword.model import Model as OpenWakeWordModel
except Exception:  # pragma: no cover - optional dependency path
    OpenWakeWordModel = None


@dataclass(frozen=True)
class WakeWordEvent:
    model: str
    score: float
    detected_at: float


class OpenWakeWordDetector:
    SAMPLE_RATE = 16_000
    CHUNK_SAMPLES = 1280
    CHUNK_BYTES = CHUNK_SAMPLES * 2

    def __init__(self, config: AssistantConfig, audio_manager: GenericAudioManager) -> None:
        self.config = config
        self.audio_manager = audio_manager
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._event_lock = threading.Lock()
        self._pending_event: WakeWordEvent | None = None
        self._last_detection = 0.0
        self._status = "disabled"
        self._model = None

    @property
    def status(self) -> str:
        return self._status

    def active(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        if self.active():
            return
        self._thread = None

        if OpenWakeWordModel is None or np is None:
            self._status = "openwakeword-or-numpy-missing"
            logging.warning("OWW disabled: openwakeword or numpy is not installed.")
            return

        if not shutil.which("arecord"):
            self._status = "arecord-missing"
            logging.warning("OWW disabled: arecord is not installed.")
            return

        try:
            self._model = self._load_model()
        except Exception as exc:
            self._status = f"model-load-failed:{exc}"
            logging.warning("OWW disabled: failed to load model %s: %s", self.config.oww_model, exc)
            return

        self._stop_event.clear()
        self._status = "starting"
        self._thread = threading.Thread(target=self._run, name="oww-detector", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def poll(self) -> WakeWordEvent | None:
        with self._event_lock:
            event = self._pending_event
            self._pending_event = None
            return event

    def _run(self) -> None:
        device = self.config.oww_input_device or self.config.generic_mic_device or self._auto_input_device()
        if not device:
            self._status = "input-device-missing"
            logging.warning("OWW disabled: no microphone input device found.")
            return

        command = [
            "arecord",
            "-q",
            "-D",
            device,
            "-r",
            str(self.SAMPLE_RATE),
            "-f",
            "S16_LE",
            "-c",
            "1",
            "-t",
            "raw",
        ]

        logging.info("Starting OWW detector using model=%s device=%s threshold=%.2f",
                     self.config.oww_model, device, self.config.oww_threshold)
        self._status = f"running:{device}"

        while not self._stop_event.is_set():
            process = None
            try:
                process = subprocess.Popen(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                stdout = process.stdout
                if stdout is None:
                    raise RuntimeError("arecord stdout unavailable")

                while not self._stop_event.is_set():
                    chunk = stdout.read(self.CHUNK_BYTES)
                    if len(chunk) < self.CHUNK_BYTES:
                        break
                    pcm = np.frombuffer(chunk, dtype=np.int16)
                    scores = self._model.predict(pcm)
                    score = self._score_for_configured_model(scores)
                    self._maybe_emit(score)
            except Exception as exc:
                self._status = f"error:{exc}"
                logging.warning("OWW detector loop error: %s", exc)
                time.sleep(2)
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        process.kill()
                if not self._stop_event.is_set():
                    self._status = "restarting"
                    time.sleep(1)

    def _maybe_emit(self, score: float) -> None:
        now = time.time()
        if score < self.config.oww_threshold:
            return
        if (now - self._last_detection) < self.config.oww_cooldown_seconds:
            return

        self._last_detection = now
        event = WakeWordEvent(
            model=self.config.oww_model,
            score=score,
            detected_at=now,
        )
        with self._event_lock:
            self._pending_event = event
        logging.info("Wake word detected: model=%s score=%.3f", event.model, event.score)

    def _load_model(self):
        model_ref = self._resolve_model_reference()
        model_path = Path(model_ref).expanduser()
        if model_path.exists():
            return OpenWakeWordModel(wakeword_model_paths=[str(model_path)])

        try:
            return OpenWakeWordModel(wakeword_models=[model_ref])
        except TypeError as exc:
            if "wakeword_models" not in str(exc):
                raise
            logging.info("OWW Model rejected wakeword_models; retrying with wakeword_model_paths.")
            return OpenWakeWordModel(wakeword_model_paths=[model_ref])

    def _resolve_model_reference(self) -> str:
        model = self.config.oww_model
        if "/" in model or "\\" in model:
            return model

        try:
            import openwakeword
        except Exception:
            return model

        bundled_models = getattr(openwakeword, "models", {})
        model_info = bundled_models.get(model)
        if isinstance(model_info, dict) and model_info.get("model_path"):
            return str(model_info["model_path"])
        return model

    def _score_for_configured_model(self, scores: dict) -> float:
        keys = [
            self.config.oww_model,
            Path(self.config.oww_model).name,
            Path(self.config.oww_model).stem,
        ]
        for key in keys:
            if key in scores:
                return float(scores[key])
        if scores:
            return float(max(scores.values()))
        return 0.0

    def _auto_input_device(self) -> str:
        status = self.audio_manager.probe()
        if status.input_ready and status.input_device not in {"managed-externally", "unavailable"}:
            return status.input_device
        return "default"
