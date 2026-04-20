from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

from assistant.config import AssistantConfig


@dataclass(frozen=True)
class HomeAssistantResult:
    ok: bool
    message: str
    data: Any = None


class HomeAssistantClient:
    def __init__(self, config: AssistantConfig) -> None:
        self.config = config

    def is_available(self) -> bool:
        return bool(self.config.home_assistant_url and self.config.home_assistant_token)

    def call_service(
        self,
        *,
        domain: str,
        service: str,
        entity_ids: list[str] | None = None,
        data: dict[str, Any] | None = None,
    ) -> HomeAssistantResult:
        if not self.is_available():
            return HomeAssistantResult(False, "Home Assistant URL/token is not configured.")

        domain = domain.strip()
        service = service.strip()
        if not domain or not service:
            return HomeAssistantResult(False, "Missing Home Assistant service domain or service name.")

        payload = dict(data or {})
        if entity_ids:
            payload["entity_id"] = entity_ids[0] if len(entity_ids) == 1 else entity_ids

        url = f"{self.config.home_assistant_url}/api/services/{domain}/{service}"
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.config.home_assistant_token}",
                "Content-Type": "application/json",
            },
        )

        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                raw = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            logging.warning("HA service call failed: %s.%s HTTP %s %s", domain, service, exc.code, detail)
            return HomeAssistantResult(False, f"Home Assistant returned HTTP {exc.code}: {detail}")
        except OSError as exc:
            logging.warning("HA service call failed: %s.%s %s", domain, service, exc)
            return HomeAssistantResult(False, f"Home Assistant request failed: {exc}")

        parsed: Any = raw
        if raw:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                pass

        target = f" for {', '.join(entity_ids)}" if entity_ids else ""
        return HomeAssistantResult(True, f"Called {domain}.{service}{target}.", parsed)
