# Smart Display Idle Screen

Standalone native idle screen for Raspberry Pi OS. It is intentionally not tied
to Home Assistant and does not use Chromium. It runs as a Pi OS idle overlay:
after inactivity it fades into a fullscreen Python/Tkinter screen with the
current time, date, weather, and a lightweight animated background.

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

## Pi Idle Install

Run this on the Pi from the repo root:

```bash
sudo apt install swayidle
chmod +x idle-screen/install-idle-screen.sh
./idle-screen/install-idle-screen.sh
```

The installer creates:

- `~/.config/smart-display-idle/config.json`
- `~/.config/smart-display-idle/start-idle-screen.sh`
- `~/.config/smart-display-idle/idle-watch.sh`
- `~/.config/autostart/smart-display-idle.desktop`
- a `~/.config/labwc/autostart` entry for Raspberry Pi OS labwc

On the next desktop login, Pi OS starts the idle watcher. The watcher launches
the screen after `idleTimeoutSeconds` and hides it again when activity resumes.

Animation can be tuned in `~/.config/smart-display-idle/config.json`:

```json
{
  "animationFps": 24,
  "animatedBackground": true
}
```

Set `animatedBackground` to `false` if you want the lowest possible CPU use.

## Assistant / Hermes Hook

The script polls the configured `stateFile`. By default this is:

```text
~/.smart-display-assistant/state.json
```

If the file is missing, the display stays in normal idle mode.

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

When the state changes from `idle` to a wake/assistant state such as
`listening`, the idle screen fades out and closes.
