#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import queue
import threading
import tkinter as tk
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from tkinter import font as tkfont
from typing import Any


APP_VERSION = "idle-v13"

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
    "stateFile": "~/.smart-display-assistant/state.json",
    "fullscreen": True,
    "fadeInMs": 450,
    "animationFps": 60,
    "animatedBackground": True,
}

WEATHER_CODES: dict[int, tuple[str, str]] = {
    0: ("Clear", "sun"),
    1: ("Mostly clear", "sun"),
    2: ("Partly cloudy", "partly"),
    3: ("Cloudy", "cloud"),
    45: ("Fog", "fog"),
    48: ("Freezing fog", "fog"),
    51: ("Light drizzle", "rain"),
    53: ("Drizzle", "rain"),
    55: ("Heavy drizzle", "rain"),
    56: ("Freezing drizzle", "rain"),
    57: ("Freezing drizzle", "rain"),
    61: ("Light rain", "rain"),
    63: ("Rain", "rain"),
    65: ("Heavy rain", "rain"),
    66: ("Freezing rain", "rain"),
    67: ("Freezing rain", "rain"),
    71: ("Light snow", "snow"),
    73: ("Snow", "snow"),
    75: ("Heavy snow", "snow"),
    77: ("Snow grains", "snow"),
    80: ("Rain showers", "rain"),
    81: ("Rain showers", "rain"),
    82: ("Heavy showers", "rain"),
    85: ("Snow showers", "snow"),
    86: ("Snow showers", "snow"),
    95: ("Thunderstorms", "storm"),
    96: ("Thunderstorms", "storm"),
    99: ("Thunderstorms", "storm"),
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
        self.weather_data = {
            "icon": "cloud",
            "temp": "--",
            "condition": "Loading weather",
            "details": "Checking local forecast",
        }
        self.assistant_state = {"state": "idle", "message": "Ready"}
        self.display_time = "--:--"
        self.display_date = "Loading date"
        self._closing = False
        self._frame = 0

        self.bg = "#05080d"
        self.bg_2 = "#07111a"
        self.panel = "#0d1721"
        self.panel_2 = "#101f2c"
        self.line = "#1d3545"
        self.fg = "#f3f8fb"
        self.muted = "#9aabba"
        self.subtle = "#66798a"
        self.accent = "#7ae7f5"
        self.accent_2 = "#315f73"
        self.warn = "#f1c66f"
        self.danger = "#ff5b6e"

        self.root.title("Smart Display Idle")
        self.root.configure(bg=self.bg)
        self.root.bind("<Escape>", lambda _event: self.root.destroy())
        self.root.bind("q", lambda _event: self.root.destroy())
        self.root.bind("<ButtonPress>", lambda _event: self.root.destroy())
        self.root.bind("<KeyPress>", lambda _event: self.root.destroy())

        fullscreen = bool(config.get("fullscreen", True))
        if fullscreen:
            screen_w = self.root.winfo_screenwidth()
            screen_h = self.root.winfo_screenheight()
            self.root.overrideredirect(True)
            self.root.geometry(f"{screen_w}x{screen_h}+0+0")
            self.root.minsize(screen_w, screen_h)
            self.root.attributes("-fullscreen", True)
            self.root.attributes("-topmost", True)
            self.root.after(100, self.force_fullscreen)
            self.root.after(750, self.force_fullscreen)
        else:
            self.root.geometry("800x480")

        self._fade_steps = max(0, int(config.get("fadeInMs", 450)) // 30)
        if self._fade_steps:
            self.root.attributes("-alpha", 0.0)

        self.build_ui()
        self.update_clock()
        self.schedule_weather()
        self.update_state()
        self.drain_weather_queue()
        self.fade_in()
        self.animate()

    def force_fullscreen(self) -> None:
        if self._closing or not bool(self.config.get("fullscreen", True)):
            return
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        self.root.geometry(f"{screen_w}x{screen_h}+0+0")
        self.root.attributes("-fullscreen", True)
        self.root.attributes("-topmost", True)
        self.root.lift()
        self.root.focus_force()
        self.canvas.configure(width=screen_w, height=screen_h)
        self.draw()

    def build_ui(self) -> None:
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)
        self.canvas = tk.Canvas(self.root, bg=self.bg, highlightthickness=0, bd=0)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        self.canvas.bind("<Configure>", lambda _event: self.rebuild_fonts_and_draw())
        self.rebuild_fonts_and_draw()

    def rebuild_fonts_and_draw(self) -> None:
        width = max(self.root.winfo_width(), self.root.winfo_screenwidth(), 800)
        height = max(self.root.winfo_height(), self.root.winfo_screenheight(), 480)
        scale = max(0.82, min(width / 800, height / 480, 1.0))

        self.label_font = tkfont.Font(family="DejaVu Sans", size=int(12 * scale), weight="bold")
        self.time_font = tkfont.Font(family="DejaVu Sans", size=int(76 * scale), weight="bold")
        self.date_font = tkfont.Font(family="DejaVu Sans", size=int(18 * scale))
        self.temp_font = tkfont.Font(family="DejaVu Sans", size=int(32 * scale), weight="bold")
        self.weather_font = tkfont.Font(family="DejaVu Sans", size=int(15 * scale), weight="bold")
        self.small_font = tkfont.Font(family="DejaVu Sans", size=int(12 * scale))
        self.status_font = tkfont.Font(family="DejaVu Sans", size=int(12 * scale), weight="bold")
        self.draw()

    def animate(self) -> None:
        if self._closing:
            return
        if bool(self.config.get("animatedBackground", True)):
            self._frame += 1
            self.draw()
        fps = max(8, min(60, int(self.config.get("animationFps", 60))))
        self.root.after(int(1000 / fps), self.animate)

    def fade_in(self, step: int = 0) -> None:
        if not self._fade_steps:
            return
        alpha = min(1.0, step / self._fade_steps)
        self.root.attributes("-alpha", alpha)
        if alpha < 1.0:
            self.root.after(30, lambda: self.fade_in(step + 1))

    def fade_out_and_close(self, step: int | None = None) -> None:
        if self._closing and step is None:
            return
        self._closing = True
        if not self._fade_steps:
            self.root.destroy()
            return

        step = self._fade_steps if step is None else step
        alpha = max(0.0, step / self._fade_steps)
        self.root.attributes("-alpha", alpha)
        if alpha <= 0.0:
            self.root.destroy()
            return
        self.root.after(24, lambda: self.fade_out_and_close(step - 1))

    def draw(self) -> None:
        if not hasattr(self, "canvas"):
            return

        width = max(self.canvas.winfo_width(), 1)
        height = max(self.canvas.winfo_height(), 1)
        margin = max(28, int(min(width, height) * 0.075))
        self.canvas.delete("all")

        self._draw_background(width, height, self._frame)
        self._draw_header(margin)
        self._draw_clock(width, height, margin)
        self._draw_weather(width, height, margin)
        self._draw_version(width, height)

        state_name = str(self.assistant_state.get("state", "idle")).lower()
        if state_name != "idle":
            self._draw_status(width, margin, state_name)

    def _draw_background(self, width: int, height: int, frame: int) -> None:
        bands = 34
        band_h = max(1, math.ceil(height / bands))
        for index in range(bands):
            ratio = index / max(bands - 1, 1)
            drift = (math.sin(frame * 0.012 + index * 0.28) + 1) / 2
            r = int(4 + 4 * ratio + 1 * drift)
            g = int(8 + 10 * ratio + 3 * drift)
            b = int(14 + 18 * ratio + 5 * drift)
            y1 = index * band_h
            self.canvas.create_rectangle(0, y1, width, min(height, y1 + band_h), fill=f"#{r:02x}{g:02x}{b:02x}", outline="")

        self._draw_aurora(width, height, frame)
        self._draw_stars(width, height, frame)
        self.canvas.create_rectangle(0, 0, width, height, outline="#0a141d", width=2)
        self.canvas.create_line(0, height - 1, width, height - 1, fill="#102633")

    def _draw_aurora(self, width: int, height: int, frame: int) -> None:
        for layer, color in enumerate(("#0b2631", "#0d3144", "#08202e")):
            base_y = height * (0.18 + layer * 0.105)
            amplitude = height * (0.026 + layer * 0.01)
            phase = frame * (0.014 + layer * 0.004)
            points: list[float] = []
            for i in range(10):
                x = width * i / 9
                y = base_y + math.sin(i * 0.82 + phase) * amplitude
                points.extend([x, y])
            self.canvas.create_line(points, fill=color, width=max(12, int(height * 0.038)), smooth=True, splinesteps=24)

    def _draw_stars(self, width: int, height: int, frame: int) -> None:
        for index in range(12):
            x = (index * 137 + frame * (0.12 + index % 3 * 0.03)) % width
            y = 35 + ((index * 53) % max(80, int(height * 0.55)))
            pulse = (math.sin(frame * 0.055 + index) + 1) / 2
            color = "#173849" if pulse < 0.65 else "#24586b"
            radius = 1 if index % 4 else 2
            self.canvas.create_oval(x - radius, y - radius, x + radius, y + radius, fill=color, outline="")

    def _draw_header(self, margin: int) -> None:
        self.canvas.create_text(
            margin,
            margin,
            text=str(self.config["displayName"]).upper(),
            anchor="nw",
            fill=self.accent,
            font=self.label_font,
        )
    def _draw_version(self, width: int, height: int) -> None:
        self.canvas.create_text(
            width - 10,
            height - 8,
            text=APP_VERSION,
            anchor="se",
            fill="#314554",
            font=self.small_font,
        )

    def _draw_clock(self, width: int, height: int, margin: int) -> None:
        y = int(height * 0.19)
        time_font = self._fitted_font(self.time_font, self.display_time, width - margin * 2)
        time_id = self.canvas.create_text(
            margin,
            y,
            text=self.display_time,
            anchor="nw",
            fill=self.fg,
            font=time_font,
        )
        bbox = self.canvas.bbox(time_id)
        date_y = bbox[3] + 2 if bbox else y + 84

        self.canvas.create_text(
            margin + 4,
            date_y,
            text=self.display_date,
            anchor="nw",
            fill=self.muted,
            font=self.date_font,
            width=width - margin * 2,
        )

    def _draw_weather(self, width: int, height: int, margin: int) -> None:
        card_w = width - margin * 2
        card_h = min(118, max(104, int(height * 0.23)))
        x1 = margin
        y1 = height - card_h - margin
        x2 = x1 + card_w
        y2 = y1 + card_h

        self._rounded_rect(x1, y1, x2, y2, radius=18, fill=self.panel, outline=self.line)
        self.canvas.create_line(x1 + 22, y1 + 1, x2 - 22, y1 + 1, fill="#214050", width=1)

        icon_size = min(66, card_h - 34)
        icon_x = x1 + 20
        icon_y = y1 + (card_h - icon_size) / 2
        self._draw_weather_icon(icon_x, icon_y, icon_size, self.weather_data["icon"])

        text_x = icon_x + icon_size + 20
        temp_id = self.canvas.create_text(
            text_x,
            y1 + 17,
            text=f"{self.weather_data['temp']}°F",
            anchor="nw",
            fill=self.fg,
            font=self.temp_font,
        )
        temp_bbox = self.canvas.bbox(temp_id)
        condition_x = temp_bbox[2] + 16 if temp_bbox else text_x + 104
        self.canvas.create_text(
            condition_x,
            y1 + 26,
            text=self.weather_data["condition"],
            anchor="nw",
            fill=self.fg,
            font=self.weather_font,
            width=max(140, x2 - condition_x - 20),
        )
        self.canvas.create_text(
            text_x,
            y1 + 70,
            text=self.weather_data["details"],
            anchor="nw",
            fill=self.muted,
            font=self.small_font,
            width=max(200, x2 - text_x - 22),
        )

    def _draw_weather_icon(self, x: float, y: float, size: float, kind: str) -> None:
        self._rounded_rect(x, y, x + size, y + size, radius=18, fill="#0c2530", outline="#1e3a49")
        cx = x + size / 2
        cy = y + size / 2
        s = size / 100

        if kind in {"sun", "partly"}:
            sun_y = cy - (12 * s if kind == "partly" else 0)
            self.canvas.create_oval(cx - 18 * s, sun_y - 18 * s, cx + 18 * s, sun_y + 18 * s, fill=self.warn, outline="")
            for angle in range(0, 360, 45):
                dx = math.cos(math.radians(angle))
                dy = math.sin(math.radians(angle))
                self.canvas.create_line(cx + dx * 25 * s, sun_y + dy * 25 * s, cx + dx * 33 * s, sun_y + dy * 33 * s, fill=self.warn, width=max(2, int(3 * s)))

        if kind in {"cloud", "partly", "rain", "snow", "storm", "fog"}:
            cloud_y = cy + (8 * s if kind == "partly" else -2 * s)
            self.canvas.create_oval(cx - 32 * s, cloud_y - 2 * s, cx - 4 * s, cloud_y + 24 * s, fill=self.accent, outline="")
            self.canvas.create_oval(cx - 18 * s, cloud_y - 17 * s, cx + 18 * s, cloud_y + 17 * s, fill=self.accent, outline="")
            self.canvas.create_oval(cx + 3 * s, cloud_y - 6 * s, cx + 34 * s, cloud_y + 23 * s, fill=self.accent, outline="")
            self.canvas.create_rectangle(cx - 30 * s, cloud_y + 8 * s, cx + 32 * s, cloud_y + 24 * s, fill=self.accent, outline="")

        if kind == "rain":
            for dx in (-18, 0, 18):
                self.canvas.create_line(cx + dx * s, cy + 24 * s, cx + (dx - 6) * s, cy + 39 * s, fill="#b7f6ff", width=max(2, int(3 * s)))
        elif kind == "snow":
            for dx in (-18, 0, 18):
                self.canvas.create_text(cx + dx * s, cy + 38 * s, text="*", anchor="center", fill="#d7f8ff", font=self.weather_font)
        elif kind == "storm":
            points = [cx - 4 * s, cy + 20 * s, cx - 16 * s, cy + 48 * s, cx + 3 * s, cy + 48 * s, cx - 5 * s, cy + 72 * s, cx + 22 * s, cy + 35 * s, cx + 4 * s, cy + 35 * s]
            self.canvas.create_polygon(points, fill=self.warn, outline="")
        elif kind == "fog":
            for offset in (22, 34, 46):
                self.canvas.create_line(cx - 34 * s, cy + offset * s, cx + 34 * s, cy + offset * s, fill=self.muted, width=max(2, int(3 * s)))

    def _draw_status(self, width: int, margin: int, state_name: str) -> None:
        if state_name == "muted":
            self._draw_muted_icon(width, margin)
            return

        message = str(self.assistant_state.get("message") or self.message_for_state(state_name))
        pill_w = max(190, min(330, len(message) * 8 + 86))
        pill_h = 48
        x2 = width - margin
        y1 = margin
        x1 = x2 - pill_w
        color = self.warn if state_name == "listening" else self.accent

        self._rounded_rect(x1, y1, x2, y1 + pill_h, radius=18, fill="#0c151d", outline=self.line)
        self.canvas.create_oval(x1 + 16, y1 + 18, x1 + 28, y1 + 30, fill=color, outline="")
        self.canvas.create_text(x1 + 42, y1 + 10, text=state_name.upper(), anchor="nw", fill=color, font=self.label_font)
        self.canvas.create_text(x1 + 42, y1 + 27, text=message, anchor="nw", fill=self.fg, font=self.status_font)

    def _draw_muted_icon(self, width: int, margin: int) -> None:
        icon_w = 74
        icon_h = 142
        x = width - margin - icon_w
        y = margin - 10
        red = self.danger

        def sx(value: float) -> float:
            return x + icon_w * value / 257

        def sy(value: float) -> float:
            return y + icon_h * value / 497

        line_w = max(4, int(icon_w * 13 / 257))
        cut_w = max(line_w + 6, int(icon_w * 25 / 257))

        body_x1 = sx(51)
        body_x2 = sx(170)
        body_y1 = sy(107)
        body_y2 = sy(341)
        body_w = body_x2 - body_x1
        self.canvas.create_oval(body_x1, body_y1, body_x2, body_y1 + body_w, fill=red, outline="")
        self.canvas.create_rectangle(body_x1, body_y1 + body_w / 2, body_x2, body_y2 - body_w / 2 + 1, fill=red, outline="")
        self.canvas.create_oval(body_x1, body_y2 - body_w, body_x2, body_y2, fill=red, outline="")

        self.canvas.create_line(sx(28), sy(222), sx(28), sy(277), fill=red, width=line_w, capstyle=tk.ROUND)
        self._draw_cubic_path(
            [
                ((28, 277), (28, 342), (77, 374), (110, 374)),
                ((110, 374), (150, 374), (193, 342), (193, 277)),
            ],
            sx,
            sy,
            fill=red,
            width=line_w,
        )
        self.canvas.create_line(sx(193), sy(222), sx(193), sy(277), fill=red, width=line_w, capstyle=tk.ROUND)

        self.canvas.create_line(sx(110), sy(374), sx(110), sy(423), fill=red, width=line_w, capstyle=tk.ROUND)
        self.canvas.create_line(sx(62), sy(431), sx(158), sy(431), fill=red, width=line_w, capstyle=tk.ROUND)
        self.canvas.create_line(sx(10), sy(128), sx(209), sy(431), fill=self.bg, width=cut_w, capstyle=tk.ROUND)
        self.canvas.create_line(sx(10), sy(128), sx(209), sy(431), fill=red, width=line_w, capstyle=tk.ROUND)

    def _draw_cubic_path(self, segments, sx, sy, *, fill: str, width: int) -> None:
        points: list[float] = []
        for index, (p0, p1, p2, p3) in enumerate(segments):
            steps = 18
            start = 0 if index == 0 else 1
            for step in range(start, steps + 1):
                t = step / steps
                mt = 1 - t
                px = (
                    mt * mt * mt * p0[0]
                    + 3 * mt * mt * t * p1[0]
                    + 3 * mt * t * t * p2[0]
                    + t * t * t * p3[0]
                )
                py = (
                    mt * mt * mt * p0[1]
                    + 3 * mt * mt * t * p1[1]
                    + 3 * mt * t * t * p2[1]
                    + t * t * t * p3[1]
                )
                points.extend([sx(px), sy(py)])
        self.canvas.create_line(points, fill=fill, width=width, capstyle=tk.ROUND, joinstyle=tk.ROUND, smooth=True)

    def _rounded_rect(self, x1: float, y1: float, x2: float, y2: float, *, radius: int, fill: str, outline: str) -> None:
        points = [
            x1 + radius, y1, x2 - radius, y1, x2, y1, x2, y1 + radius,
            x2, y2 - radius, x2, y2, x2 - radius, y2, x1 + radius, y2,
            x1, y2, x1, y2 - radius, x1, y1 + radius, x1, y1,
        ]
        self.canvas.create_polygon(points, smooth=True, splinesteps=16, fill=fill, outline=outline)

    @staticmethod
    def _fitted_font(source: tkfont.Font, text: str, max_width: int) -> tkfont.Font:
        size = int(source.cget("size"))
        fitted = tkfont.Font(
            family=str(source.cget("family")),
            size=size,
            weight=str(source.cget("weight")),
        )
        while size > 24 and fitted.measure(text) > max_width:
            size -= 4
            fitted.configure(size=size)
        return fitted

    def update_clock(self) -> None:
        now = datetime.now()
        time_format = str(self.config.get("timeFormat", "auto")).lower()
        if time_format == "24h":
            self.display_time = now.strftime("%H:%M")
        else:
            self.display_time = now.strftime("%I:%M").lstrip("0")
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
                "current": "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m",
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
            condition, icon = WEATHER_CODES.get(int(current["weather_code"]), ("Current weather", "cloud"))
            temp_unit = self._clean_temp_unit(str(units.get("temperature_2m", "°F")))
            wind_unit = self._clean_wind_unit(str(units.get("wind_speed_10m", "mph")))
            wind_direction = self._cardinal_direction(current.get("wind_direction_10m"))
            wind_label = " ".join(
                part for part in (
                    wind_direction,
                    round_number(current.get("wind_speed_10m")),
                    wind_unit,
                )
                if part
            )
            self.weather_queue.put(
                {
                    "icon": icon,
                    "temp": round_number(current.get("temperature_2m")),
                    "condition": condition,
                    "details": (
                        f"{self.config['weatherLocation']}  |  "
                        f"Feels like {round_number(current.get('apparent_temperature'))}"
                        f"{temp_unit}  |  "
                        f"Wind {wind_label}"
                    ),
                }
            )
        except Exception:
            self.weather_queue.put(
                {
                    "icon": "cloud",
                    "temp": "--",
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
        if name not in {"idle", "muted"}:
            self.fade_out_and_close()
            return

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
            "muted": "Muted",
            "error": "Assistant needs attention",
        }.get(state, "Ready")

    @staticmethod
    def _clean_temp_unit(unit: str) -> str:
        return unit.replace("°", "°").replace("deg", "°") or "°F"

    @staticmethod
    def _clean_wind_unit(unit: str) -> str:
        return "mph" if unit.strip().lower() in {"mp/h", "mph"} else unit.strip()

    @staticmethod
    def _cardinal_direction(degrees: Any) -> str:
        try:
            value = float(degrees) % 360
        except (TypeError, ValueError):
            return ""
        directions = ("N", "NE", "E", "SE", "S", "SW", "W", "NW")
        return directions[int((value + 22.5) // 45) % 8]


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
