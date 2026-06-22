#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import queue
import threading
import time
import tkinter as tk
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from tkinter import font as tkfont
from typing import Any


DEFAULT_CONFIG: dict[str, Any] = {
    "displayName": "Smart Display",
    "latitude": 40.7128,
    "longitude": -74.006,
    "weatherLocation": "New York",
    "temperatureUnit": "fahrenheit",
    "windSpeedUnit": "mph",
    "timeFormat": "auto",
    "refreshMinutes": 10,
    "statePollSeconds": 2,
    "stateFile": "~/.config/smart-display-idle/state.json",
    "fullscreen": True,
}

WEATHER_CODES: dict[int, tuple[str, str]] = {
    0: ("Clear", "☀"),
    1: ("Mostly clear", "☀"),
    2: ("Partly cloudy", "⛅"),
    3: ("Cloudy", "☁"),
    45: ("Fog", "≋"),
    48: ("Freezing fog", "≋"),
    51: ("Light drizzle", "☔"),
    53: ("Drizzle", "☔"),
    55: ("Heavy drizzle", "☔"),
    56: ("Freezing drizzle", "☔"),
    57: ("Freezing drizzle", "☔"),
    61: ("Light rain", "☔"),
    63: ("Rain", "☔"),
    65: ("Heavy rain", "☔"),
    66: ("Freezing rain", "☔"),
    67: ("Freezing rain", "☔"),
    71: ("Light snow", "❄"),
    73: ("Snow", "❄"),
    75: ("Heavy snow", "❄"),
    77: ("Snow grains", "❄"),
    80: ("Rain showers", "☔"),
    81: ("Rain showers", "☔"),
    82: ("Heavy showers", "☔"),
    85: ("Snow showers", "❄"),
    86: ("Snow showers", "❄"),
    95: ("Thunderstorms", "⚡"),
    96: ("Thunderstorms", "⚡"),
    99: ("Thunderstorms", "⚡"),
}


def load_config(path: Path | None) -> dict[str, Any]:
    config = dict(DEFAULT_CONFIG)
    if path and path.exists():
        with path.open("r", encoding="utf-8") as handle:
            config.update(json.load(handle))
    return config


def round_number(value: Any) -> str:
    try:
        if value is None or math.isnan(float(value)):
            return "--"
        return str(round(float(value)))
    except (TypeError, ValueError):
        return "--"


class IdleScreen:
    def __init__(self, root: tk.Tk, config: dict[str, Any]) -> None:
        self.root = root
        self.config = config
        self.weather_queue: queue.Queue[dict[str, str]] = queue.Queue()
        self.state_path = Path(str(config["stateFile"])).expanduser()

        self.bg = "#071014"
        self.panel = "#0b2028"
        self.fg = "#f5fbff"
        self.muted = "#aac0c9"
        self.accent = "#7bdff2"
        self.warn = "#ffcf70"

        self.root.title("Smart Display Idle Screen")
        self.root.configure(bg=self.bg)
        self.root.bind("<Escape>", lambda _event: self.root.destroy())
        self.root.bind("q", lambda _event: self.root.destroy())
        self.root.attributes("-fullscreen", bool(config.get("fullscreen", True)))

        self.build_ui()
        self.update_clock()
        self.schedule_weather()
        self.update_state()
        self.drain_weather_queue()

    def build_ui(self) -> None:
        width = max(self.root.winfo_screenwidth(), 800)
        scale = width / 800

        self.time_font = tkfont.Font(family="DejaVu Sans", size=int(92 * scale), weight="bold")
        self.date_font = tkfont.Font(family="DejaVu Sans", size=int(22 * scale))
        self.label_font = tkfont.Font(family="DejaVu Sans", size=int(14 * scale), weight="bold")
        self.temp_font = tkfont.Font(family="DejaVu Sans", size=int(52 * scale), weight="bold")
        self.weather_font = tkfont.Font(family="DejaVu Sans", size=int(18 * scale), weight="bold")
        self.small_font = tkfont.Font(family="DejaVu Sans", size=int(13 * scale))
        self.mark_font = tkfont.Font(family="DejaVu Sans", size=int(48 * scale), weight="bold")

        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        main = tk.Frame(self.root, bg=self.bg, padx=36, pady=28)
        main.grid(row=0, column=0, sticky="nsew")
        main.columnconfigure(0, weight=1)
        main.rowconfigure(0, weight=1)

        clock = tk.Frame(main, bg=self.bg)
        clock.grid(row=0, column=0, sticky="sw")

        tk.Label(
            clock,
            text=str(self.config["displayName"]).upper(),
            fg=self.accent,
            bg=self.bg,
            font=self.label_font,
        ).pack(anchor="w")

        self.time_label = tk.Label(clock, text="--:--", fg=self.fg, bg=self.bg, font=self.time_font)
        self.time_label.pack(anchor="w")

        self.date_label = tk.Label(clock, text="Loading date", fg=self.muted, bg=self.bg, font=self.date_font)
        self.date_label.pack(anchor="w")

        weather = tk.Frame(main, bg=self.panel, padx=22, pady=18)
        weather.grid(row=1, column=0, sticky="ew", pady=(28, 0))
        weather.columnconfigure(1, weight=1)

        self.weather_mark = tk.Label(weather, text="--", fg=self.accent, bg=self.panel, font=self.mark_font, width=3)
        self.weather_mark.grid(row=0, column=0, rowspan=3, sticky="nsew", padx=(0, 20))

        self.temp_label = tk.Label(weather, text="--°", fg=self.fg, bg=self.panel, font=self.temp_font)
        self.temp_label.grid(row=0, column=1, sticky="w")

        self.condition_label = tk.Label(
            weather,
            text="Loading weather",
            fg=self.fg,
            bg=self.panel,
            font=self.weather_font,
        )
        self.condition_label.grid(row=1, column=1, sticky="w")

        self.details_label = tk.Label(
            weather,
            text="Checking local forecast...",
            fg=self.muted,
            bg=self.panel,
            font=self.small_font,
        )
        self.details_label.grid(row=2, column=1, sticky="w")

        self.status_frame = tk.Frame(main, bg=self.bg, padx=12, pady=8, highlightthickness=1, highlightbackground="#294650")
        self.status_label = tk.Label(self.status_frame, text="IDLE", fg=self.accent, bg=self.bg, font=self.label_font)
        self.status_label.pack(anchor="e")
        self.status_message = tk.Label(self.status_frame, text="Ready", fg=self.fg, bg=self.bg, font=self.small_font)
        self.status_message.pack(anchor="e")

    def update_clock(self) -> None:
        now = datetime.now()
        time_format = str(self.config.get("timeFormat", "auto")).lower()
        if time_format == "24h":
            display_time = now.strftime("%H:%M")
        else:
            display_time = now.strftime("%I:%M %p").lstrip("0")
        self.time_label.configure(text=display_time)
        self.date_label.configure(text=f"{now:%A}, {now:%B} {now.day}")
        self.root.after(1000, self.update_clock)

    def schedule_weather(self) -> None:
        threading.Thread(target=self.fetch_weather, daemon=True).start()
        delay = int(max(1, float(self.config["refreshMinutes"])) * 60 * 1000)
        self.root.after(delay, self.schedule_weather)

    def fetch_weather(self) -> None:
        params = urllib.parse.urlencode(
            {
                "latitude": self.config["latitude"],
                "longitude": self.config["longitude"],
                "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m",
                "temperature_unit": self.config["temperatureUnit"],
                "wind_speed_unit": self.config["windSpeedUnit"],
                "timezone": "auto",
            }
        )
        url = f"https://api.open-meteo.com/v1/forecast?{params}"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
            current = data["current"]
            units = data.get("current_units", {})
            condition, mark = WEATHER_CODES.get(int(current["weather_code"]), ("Current weather", "WX"))
            self.weather_queue.put(
                {
                    "mark": mark,
                    "temp": f"{round_number(current.get('temperature_2m'))}°",
                    "condition": condition,
                    "details": (
                        f"{self.config['weatherLocation']} | "
                        f"Feels like {round_number(current.get('apparent_temperature'))}"
                        f"{units.get('temperature_2m', '')} | "
                        f"Wind {round_number(current.get('wind_speed_10m'))} {units.get('wind_speed_10m', '')}"
                    ),
                }
            )
        except Exception:
            self.weather_queue.put(
                {
                    "mark": "--",
                    "temp": "--°",
                    "condition": "Weather unavailable",
                    "details": "Check network or location settings.",
                }
            )

    def drain_weather_queue(self) -> None:
        while not self.weather_queue.empty():
            weather = self.weather_queue.get_nowait()
            self.weather_mark.configure(text=weather["mark"])
            self.temp_label.configure(text=weather["temp"])
            self.condition_label.configure(text=weather["condition"])
            self.details_label.configure(text=weather["details"])
        self.root.after(500, self.drain_weather_queue)

    def update_state(self) -> None:
        try:
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            state = {"state": "idle"}

        name = str(state.get("state", "idle")).lower()
        if name == "idle":
            self.status_frame.grid_forget()
        else:
            self.status_label.configure(text=name.upper(), fg=self.warn if name == "listening" else self.accent)
            self.status_message.configure(text=str(state.get("message") or self.message_for_state(name)))
            self.status_frame.grid(row=0, column=0, sticky="ne")

        delay = int(max(1, float(self.config["statePollSeconds"])) * 1000)
        self.root.after(delay, self.update_state)

    @staticmethod
    def message_for_state(state: str) -> str:
        return {
            "listening": "Listening",
            "processing": "Thinking",
            "responding": "Speaking",
            "muted": "Microphone muted",
            "error": "Assistant needs attention",
        }.get(state, "Ready")


def main() -> None:
    parser = argparse.ArgumentParser(description="Native Raspberry Pi OS idle screen.")
    parser.add_argument("--config", type=Path, default=None, help="Path to idle screen config JSON.")
    args = parser.parse_args()

    config = load_config(args.config)
    root = tk.Tk()
    IdleScreen(root, config)
    root.mainloop()


if __name__ == "__main__":
    main()
