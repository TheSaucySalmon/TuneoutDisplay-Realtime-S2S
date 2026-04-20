from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from typing import Any


@dataclass(frozen=True)
class MemoryEntry:
    id: str
    text: str
    category: str
    created_at: float
    source_device: str


class MemoryStore:
    def __init__(self, memory_path: Path, device_id: str, max_entries: int = 300) -> None:
        self.memory_path = memory_path
        self.device_id = device_id
        self.max_entries = max_entries
        self.file_path = memory_path / "shared_memory.json"
        self._lock = Lock()
        self._entries: list[MemoryEntry] = []
        self.load()

    def load(self) -> None:
        with self._lock:
            self.memory_path.mkdir(parents=True, exist_ok=True)
            if not self.file_path.exists():
                self._entries = []
                return

            try:
                raw = json.loads(self.file_path.read_text(encoding="utf-8"))
                self._entries = [self._entry_from_dict(item) for item in raw.get("entries", [])]
            except Exception as exc:
                logging.warning("Failed to load assistant memory: %s", exc)
                self._entries = []

    def add(self, text: str, category: str = "general") -> MemoryEntry:
        text = text.strip()
        category = category.strip() or "general"
        if not text:
            raise ValueError("memory text is required")

        entry = MemoryEntry(
            id=str(uuid.uuid4()),
            text=text,
            category=category,
            created_at=time.time(),
            source_device=self.device_id,
        )
        with self._lock:
            self._entries.append(entry)
            self._dedupe_and_trim()
            self._save_locked()
        return entry

    def search(self, query: str, limit: int = 5) -> list[MemoryEntry]:
        query_tokens = _tokens(query)
        with self._lock:
            entries = list(self._entries)

        if not query_tokens:
            return sorted(entries, key=lambda item: item.created_at, reverse=True)[:limit]

        scored: list[tuple[int, float, MemoryEntry]] = []
        for entry in entries:
            entry_tokens = _tokens(f"{entry.category} {entry.text}")
            score = len(query_tokens & entry_tokens)
            if score:
                scored.append((score, entry.created_at, entry))

        scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
        return [entry for _, _, entry in scored[:limit]]

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            entries = [entry.__dict__ for entry in self._entries]
        return {
            "version": 1,
            "updated_at": time.time(),
            "source_device": self.device_id,
            "entries": entries,
        }

    def merge_snapshot(self, snapshot: dict[str, Any]) -> bool:
        incoming = snapshot.get("entries", [])
        if not isinstance(incoming, list):
            return False

        changed = False
        with self._lock:
            by_id = {entry.id: entry for entry in self._entries}
            for item in incoming:
                try:
                    entry = self._entry_from_dict(item)
                except Exception:
                    continue
                if entry.id not in by_id:
                    by_id[entry.id] = entry
                    changed = True

            if changed:
                self._entries = list(by_id.values())
                self._dedupe_and_trim()
                self._save_locked()
        return changed

    def _dedupe_and_trim(self) -> None:
        seen_text: set[tuple[str, str]] = set()
        deduped: list[MemoryEntry] = []
        for entry in sorted(self._entries, key=lambda item: item.created_at, reverse=True):
            key = (entry.category.lower(), entry.text.lower())
            if key in seen_text:
                continue
            seen_text.add(key)
            deduped.append(entry)
        self._entries = sorted(deduped[: self.max_entries], key=lambda item: item.created_at)

    def _save_locked(self) -> None:
        payload = {
            "version": 1,
            "updated_at": time.time(),
            "source_device": self.device_id,
            "entries": [entry.__dict__ for entry in self._entries],
        }
        self.file_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

    def _entry_from_dict(self, item: dict[str, Any]) -> MemoryEntry:
        return MemoryEntry(
            id=str(item["id"]),
            text=str(item["text"]),
            category=str(item.get("category", "general") or "general"),
            created_at=float(item.get("created_at", time.time())),
            source_device=str(item.get("source_device", "unknown")),
        )


def _tokens(text: str) -> set[str]:
    return {
        token
        for token in "".join(char.lower() if char.isalnum() else " " for char in text).split()
        if len(token) > 2
    }
