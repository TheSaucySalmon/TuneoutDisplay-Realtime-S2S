from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass
from typing import IO, Iterable

from assistant.config import AssistantConfig


@dataclass(frozen=True)
class AudioStatus:
    profile: str
    input_device: str
    output_device: str
    input_ready: bool
    output_ready: bool
    details: str


class GenericAudioManager:
    def __init__(self, config: AssistantConfig) -> None:
        self.config = config

    def probe(self) -> AudioStatus:
        if self.config.audio_profile != "generic_usb":
            return AudioStatus(
                profile=self.config.audio_profile,
                input_device="managed-externally",
                output_device="managed-externally",
                input_ready=True,
                output_ready=True,
                details="audio profile uses dedicated hardware configuration",
            )

        input_device = self.config.generic_mic_device or self._detect_arecord_device()
        output_device = self.config.generic_speaker_device or self._detect_output_device()
        input_ready = bool(input_device)
        output_ready = bool(output_device)

        details_parts: list[str] = []
        if self.config.generic_mic_device:
            details_parts.append("mic=env")
        elif input_ready:
            details_parts.append("mic=auto")
        else:
            details_parts.append("mic=missing")

        if self.config.generic_speaker_device:
            details_parts.append("speaker=env")
        elif output_ready:
            details_parts.append("speaker=auto")
        else:
            details_parts.append("speaker=missing")

        return AudioStatus(
            profile=self.config.audio_profile,
            input_device=input_device or "unavailable",
            output_device=output_device or "unavailable",
            input_ready=input_ready,
            output_ready=output_ready,
            details=", ".join(details_parts),
        )

    def capture_device(self) -> str:
        if self.config.audio_profile == "seeed_2mic_hat":
            return self.config.generic_mic_device or "default"

        if self.config.generic_mic_device:
            return self.config.generic_mic_device

        detected = self._detect_arecord_device()
        return detected or "default"

    def playback_device(self) -> str:
        if self.config.audio_profile == "seeed_2mic_hat":
            return "seeed_tts"
        return self.config.generic_speaker_device or "default"

    def start_capture_process(self, sample_rate: int) -> subprocess.Popen[bytes]:
        command = [
            "arecord",
            "-q",
            "-D",
            self.capture_device(),
            "-r",
            str(sample_rate),
            "-f",
            "S16_LE",
            "-c",
            "1",
            "-t",
            "raw",
        ]
        logging.info("Starting capture command: %s", " ".join(command))
        return subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

    def start_playback_process(self, sample_rate: int) -> subprocess.Popen[bytes]:
        command = [
            "aplay",
            "-q",
            "-D",
            self.playback_device(),
            "-r",
            str(sample_rate),
            "-f",
            "S16_LE",
            "-c",
            "1",
            "-t",
            "raw",
        ]
        logging.info("Starting playback command: %s", " ".join(command))
        return subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

    def stop_process(self, process: subprocess.Popen[bytes] | None, stream: IO[bytes] | None = None) -> None:
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass

        if process is None:
            return

        if process.poll() is None:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()

    def _detect_arecord_device(self) -> str:
        output = self._run_lines(["arecord", "-L"])
        for line in output:
            candidate = line.strip()
            if not candidate or candidate.startswith("#"):
                continue
            if candidate.startswith(("null", "sysdefault", "lavrate", "samplerate", "speex", "jack", "oss")):
                continue
            lowered = candidate.lower()
            if any(token in lowered for token in ("usb", "mic", "pulse", "default", "plughw", "hw:")):
                return candidate
        return ""

    def _detect_output_device(self) -> str:
        pactl_path = shutil.which("pactl")
        if pactl_path:
            output = self._run_lines([pactl_path, "list", "short", "sinks"])
            for line in output:
                parts = line.split("\t")
                if len(parts) >= 2 and parts[1].strip():
                    return parts[1].strip()

        output = self._run_lines(["aplay", "-L"])
        for line in output:
            candidate = line.strip()
            if not candidate or candidate.startswith("#"):
                continue
            if candidate.startswith(("null", "sysdefault", "lavrate", "samplerate", "speex", "jack", "oss")):
                continue
            lowered = candidate.lower()
            if any(token in lowered for token in ("usb", "pulse", "default", "plughw", "hw:")):
                return candidate
        return ""

    def _run_lines(self, command: list[str]) -> list[str]:
        if not shutil.which(command[0]):
            return []

        try:
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except OSError as exc:
            logging.debug("Audio probe failed for %s: %s", command[0], exc)
            return []
        except subprocess.TimeoutExpired:
            logging.debug("Audio probe timed out for %s", command[0])
            return []

        if completed.returncode != 0:
            logging.debug("Audio probe returned %s for %s", completed.returncode, command)
            return []
        return list(_nonempty_lines(completed.stdout.splitlines()))


def _nonempty_lines(lines: Iterable[str]) -> Iterable[str]:
    for line in lines:
        if line.strip():
            yield line
