# Smart Display Idle Screen

Standalone native idle screen for Raspberry Pi OS. It is intentionally not tied
to Home Assistant and does not use Chromium. It launches a fullscreen Python
Tkinter window that shows the current time, date, and weather.

The weather source is [Open-Meteo](https://open-meteo.com/), so no API key is
required. You only need latitude and longitude.

## Quick Test

From this folder:

```bash
python3 idle_screen.py --config config.example.json
```

Copy `config.example.json` to `config.json` if you want a local editable config:

```bash
cp config.example.json config.json
nano config.json
python3 idle_screen.py --config config.json
```

## Pi Kiosk Install

Run this on the Pi from the repo root:

```bash
chmod +x idle-screen/install-idle-screen.sh
./idle-screen/install-idle-screen.sh
```

The installer creates:

- `~/.config/smart-display-idle/config.json`
- `~/.config/smart-display-idle/start-idle-screen.sh`
- `~/.config/autostart/smart-display-idle.desktop`

On the next desktop login, Pi OS starts the idle screen directly with Python.

## Future Assistant / Hermes Hook

The script polls the configured `stateFile`. If the file is missing, the display
stays in normal idle mode.

A future assistant runtime, Hermes Agent, or small bridge can write this shape:

```json
{
  "state": "listening",
  "message": "Listening"
}
```

Supported state values are flexible, but these are the useful ones:

- `idle`
- `listening`
- `processing`
- `responding`
- `muted`
- `error`

When the state returns to `idle`, the screen goes back to the clock-first idle
view.
