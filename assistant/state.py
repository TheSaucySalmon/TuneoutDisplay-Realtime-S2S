from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any

VALID_STATES = {"idle", "listening", "processing", "responding", "muted", "error"}


class AssistantStateStore:
    def __init__(self, state_path: Path, mute_path: Path) -> None:
        self._state_path = state_path
        self._mute_path = mute_path
        self._lock = threading.Lock()
        self._state_path.parent.mkdir(parents=True, exist_ok=True)
        self._mute_path.parent.mkdir(parents=True, exist_ok=True)
        self._state = self._load_state()

    def _load_state(self) -> dict[str, Any]:
        muted = self._read_muted()
        default_state = "muted" if muted else "idle"
        try:
            raw = json.loads(self._state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            raw = {}

        state = str(raw.get("state", default_state)).strip().lower()
        if state not in VALID_STATES:
            state = default_state

        return {
            "state": state,
            "muted": muted,
            "updated_at": float(raw.get("updated_at", time.time())),
        }

    def _read_muted(self) -> bool:
        try:
            return self._mute_path.read_text(encoding="utf-8").strip() == "1"
        except OSError:
            return False

    def _write_muted(self, muted: bool) -> None:
        self._mute_path.write_text("1" if muted else "0", encoding="utf-8")

    def _persist(self) -> None:
        self._state_path.write_text(json.dumps(self._state, indent=2), encoding="utf-8")

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    def current_state(self) -> str:
        with self._lock:
            return "muted" if self._state["muted"] else self._state["state"]

    def is_muted(self) -> bool:
        with self._lock:
            return bool(self._state["muted"])

    def set_muted(self, muted: bool) -> dict[str, Any]:
        with self._lock:
            self._state["muted"] = bool(muted)
            self._state["state"] = "muted" if muted else "idle"
            self._state["updated_at"] = time.time()
            self._write_muted(bool(muted))
            self._persist()
            return dict(self._state)

    def set_state(self, state: str) -> dict[str, Any]:
        normalized = str(state).strip().lower()
        if normalized not in VALID_STATES:
            raise ValueError(f"invalid assistant state: {state}")
        with self._lock:
            if self._state["muted"]:
                normalized = "muted"
            self._state["state"] = normalized
            self._state["updated_at"] = time.time()
            self._persist()
            return dict(self._state)
