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

        self.weather_data = {
            "mark": "--",
            "temp": "--°",
            "condition": "Loading weather",
            "details": "Checking local forecast...",
        }
        self.assistant_state = {"state": "idle", "message": "Ready"}

        self.build_ui()
        self.update_clock()
        self.schedule_weather()
        self.update_state()
        self.drain_weather_queue()

    def build_ui(self) -> None:
        width = max(self.root.winfo_screenwidth(), 800)
        scale = width / 800

        self.time_font = tkfont.Font(family="DejaVu Sans", size=int(112 * scale), weight="bold")
        self.date_font = tkfont.Font(family="DejaVu Sans", size=int(19 * scale))
        self.label_font = tkfont.Font(family="DejaVu Sans", size=int(11 * scale), weight="bold")
        self.temp_font = tkfont.Font(family="DejaVu Sans", size=int(46 * scale), weight="bold")
        self.weather_font = tkfont.Font(family="DejaVu Sans", size=int(18 * scale), weight="bold")
        self.small_font = tkfont.Font(family="DejaVu Sans", size=int(12 * scale))
        self.mark_font = tkfont.Font(family="DejaVu Sans", size=int(54 * scale), weight="bold")
        self.status_font = tkfont.Font(family="DejaVu Sans", size=int(12 * scale), weight="bold")

        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        self.canvas = tk.Canvas(self.root, bg=self.bg, highlightthickness=0, bd=0)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.canvas.bind("<Configure>", lambda _event: self.draw())

    def draw(self) -> None:
        if not hasattr(self, "canvas"):
            return

        width = max(self.canvas.winfo_width(), 1)
        height = max(self.canvas.winfo_height(), 1)
        margin = max(28, int(width * 0.045))
        bottom_margin = max(24, int(height * 0.055))

        self.canvas.delete("all")
        self._draw_background(width, height)

        self.canvas.create_text(
            margin,
            margin,
            text=str(self.config["displayName"]).upper(),
            anchor="nw",
            fill=self.accent,
            font=self.label_font,
        )

        self.canvas.create_text(
            margin,
            margin + 30,
            text=getattr(self, "display_time", "--:--"),
            anchor="nw",
            fill=self.fg,
            font=self.time_font,
        )

        self.canvas.create_text(
            margin + 5,
            margin + int(height * 0.285),
            text=getattr(self, "display_date", "Loading date"),
            anchor="nw",
            fill=self.muted,
            font=self.date_font,
        )

        weather_w = min(width - (margin * 2), int(width * 0.78))
        weather_h = max(148, int(height * 0.24))
        weather_x = margin
        weather_y = height - weather_h - bottom_margin
        self._rounded_rect(
            weather_x,
            weather_y,
            weather_x + weather_w,
            weather_y + weather_h,
            radius=26,
            fill=self.panel,
            outline="#1f3a44",
        )

        icon_box = min(weather_h - 44, 130)
        icon_x = weather_x + 26
        icon_y = weather_y + (weather_h - icon_box) / 2
        self._rounded_rect(
            icon_x,
            icon_y,
            icon_x + icon_box,
            icon_y + icon_box,
            radius=24,
            fill="#102b35",
            outline="#294650",
        )
        self.canvas.create_text(
            icon_x + icon_box / 2,
            icon_y + icon_box / 2,
            text=self.weather_data["mark"],
            anchor="center",
            fill=self.accent,
            font=self.mark_font,
        )

        content_x = icon_x + icon_box + 26
        self.canvas.create_text(
            content_x,
            weather_y + 26,
            text=self.weather_data["temp"],
            anchor="nw",
            fill=self.fg,
            font=self.temp_font,
        )
        self.canvas.create_text(
            content_x,
            weather_y + 86,
            text=self.weather_data["condition"],
            anchor="nw",
            fill=self.fg,
            font=self.weather_font,
            width=max(180, weather_w - (content_x - weather_x) - 22),
        )
        self.canvas.create_text(
            content_x,
            weather_y + 116,
            text=self.weather_data["details"],
            anchor="nw",
            fill=self.muted,
            font=self.small_font,
            width=max(180, weather_w - (content_x - weather_x) - 22),
        )

        state_name = str(self.assistant_state.get("state", "idle")).lower()
        if state_name != "idle":
            self._draw_status(width, margin, state_name)

    def _draw_background(self, width: int, height: int) -> None:
        bands = 56
        band_h = max(1, math.ceil(height / bands))
        for index in range(bands):
            y1 = index * band_h
            y2 = min(height, y1 + band_h)
            ratio = index / max(bands - 1, 1)
            r = int(5 + (10 * ratio))
            g = int(14 + (14 * ratio))
            b = int(20 + (19 * ratio))
            self.canvas.create_rectangle(0, y1, width, y2, fill=f"#{r:02x}{g:02x}{b:02x}", outline="")

        self.canvas.create_oval(
            -int(width * 0.18),
            -int(height * 0.35),
            int(width * 0.55),
            int(height * 0.55),
            fill="#0d2a32",
            outline="",
        )
        self.canvas.create_oval(
            int(width * 0.62),
            int(height * 0.06),
            int(width * 1.18),
            int(height * 0.68),
            fill="#10242d",
            outline="",
        )

    def _draw_status(self, width: int, margin: int, state_name: str) -> None:
        message = str(self.assistant_state.get("message") or self.message_for_state(state_name))
        pill_w = max(190, min(360, len(message) * 9 + 92))
        pill_h = 54
        x2 = width - margin
        y1 = margin
        x1 = x2 - pill_w
        color = self.warn if state_name == "listening" else self.accent

        self._rounded_rect(x1, y1, x2, y1 + pill_h, radius=22, fill="#0b2028", outline="#294650")
        self.canvas.create_oval(x1 + 18, y1 + 21, x1 + 30, y1 + 33, fill=color, outline="")
        self.canvas.create_text(
            x1 + 44,
            y1 + 13,
            text=state_name.upper(),
            anchor="nw",
            fill=color,
            font=self.label_font,
        )
        self.canvas.create_text(
            x1 + 44,
            y1 + 31,
            text=message,
            anchor="nw",
            fill=self.fg,
            font=self.status_font,
        )

    def _rounded_rect(self, x1: float, y1: float, x2: float, y2: float, *, radius: int, fill: str, outline: str) -> None:
        points = [
            x1 + radius,
            y1,
            x2 - radius,
            y1,
            x2,
            y1,
            x2,
            y1 + radius,
            x2,
            y2 - radius,
            x2,
            y2,
            x2 - radius,
            y2,
            x1 + radius,
            y2,
            x1,
            y2,
            x1,
            y2 - radius,
            x1,
            y1 + radius,
            x1,
            y1,
        ]
        self.canvas.create_polygon(points, smooth=True, splinesteps=16, fill=fill, outline=outline)

    def update_clock(self) -> None:
        now = datetime.now()
        time_format = str(self.config.get("timeFormat", "auto")).lower()
        if time_format == "24h":
            display_time = now.strftime("%H:%M")
        else:
            display_time = now.strftime("%I:%M %p").lstrip("0")
        self.display_time = display_time
        self.display_date = f"{now:%A}, {now:%B} {now.day}"
        self.draw()
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
            self.weather_data = self.weather_queue.get_nowait()
            self.draw()
        self.root.after(500, self.drain_weather_queue)

    def update_state(self) -> None:
        try:
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            state = {"state": "idle"}

        name = str(state.get("state", "idle")).lower()
        self.assistant_state = {
            "state": name,
            "message": str(state.get("message") or self.message_for_state(name)),
        }
        self.draw()

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
