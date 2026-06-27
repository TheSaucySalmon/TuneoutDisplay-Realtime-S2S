# Smart Display

> **Working title.** "Smart Display" is a placeholder name (set in
> `smart_display/lib/main.dart` as `kAppName`) until a public release.

A Raspberry Pi 5 wall/desk **smart display** for Home Assistant: a native Flutter
dashboard with an iOS-style "liquid glass" aesthetic that boots fullscreen under
labwc, alongside an on-device voice-assistant / audio / MQTT stack. The Flutter
dashboard is the current focus; the voice/audio/MQTT layer is inherited and being
rebuilt for this project's own direction.

## Credits

Derived from [TuneoutDisplay](https://github.com/zmsaunders/TuneoutDisplay) by
[zmsaunders](https://github.com/zmsaunders) — this started from that project's
Raspberry Pi smart-display / Home Assistant concept. The UI has since been
rebuilt as a native Flutter app, and the voice path uses OpenAI GPT-Realtime
speech-to-speech. See the [License](#license) section regarding attribution.

## Full Disclosure

A personal, spare-time project — not a polished product. Parts were built with the
help of AI coding assistants, and the author is still new to Raspberry Pi and
Linux, so expect rough edges and occasional imprecise wording.

---

## Hardware

| Component | Details |
|---|---|
| SBC | Raspberry Pi 5 (4GB or 8GB of RAM) |
| Microphone / Audio | User preference |
| Display | Raspberry Pi Official 7" DSI Touchscreen |
| Speaker | 3W 8 ohm (Recommended, USB device works fine too.) |
| OS | Raspberry Pi OS 64-bit (Trixie / Debian 13), kernel 6.12.x |
| Compositor | labwc (Wayland / wlroots) |
| Cooling | **Active cooling required** (see below) |

> [!IMPORTANT]
> **Active cooling is required, not optional.** The Raspberry Pi 5 runs hot, and
> this project drives a continuously-rendered display alongside an always-on
> wake-word assistant. With no heatsink/fan the board reaches ~85 °C and
> thermally throttles (slowing everything down). Use the official **Raspberry Pi
> 5 Active Cooler**, or any fan + heatsink / actively-cooled case, and make sure
> the enclosure has airflow. Check temps with `vcgencmd measure_temp` and
> `vcgencmd get_throttled` (`throttled=0x0` and temps in the 50s–60s °C are
> healthy; sustained 80 °C+ means it's throttling).

This repo currently supports both `seeed_2mic_hat` / WM8960 setups and `generic_usb` setups using USB microphones and USB speakers/headsets.

Generic USB devices can expose HA MQTT number entities for:

- assistant / voice volume
- speaker volume
- mic sensitivity
- brightness

On `generic_usb`, voice and speaker volume currently point at the same underlying USB output path.

---

## Features

- **Native display shell** - Flutter app (`smart_display/`) that boots fullscreen under labwc: liquid-glass dashboard, static idle screensaver, live HA entities, weather, and camera snapshots. No browser. In-app edit mode with multi-page layouts, per-card config, and per-domain entity controls.
- **OpenAI Realtime first-pass integration** - Assistant runtime can open a Realtime session, stream mic audio, and play returned model audio
- **Wake-word runtime path** - OpenWakeWord is wired in as the wake gate for the assistant runtime
- **Home Assistant voice control path** - Realtime can call HA services for entities, scenes, scripts, and helpers
- **Shared local memory** - Each Pi stores memory locally and syncs a retained snapshot over MQTT, no database required
- **Manual HA trigger** - Assistant runtime exposes an HA button entity for manual Realtime testing
- **Music Assistant playback** - Sendspin native player; appears automatically in MA 2.7+
- **MQTT auto-discovery** - Device registers itself in HA with assistant state, mute, audio status, and control entities
- **Touch scrolling** - Daemon translates touchscreen swipe gestures into scroll-wheel events for labwc/Wayland
- **Independent volume channels on Seeed audio** - TTS/voice and media are separate ALSA softvol streams on the WM8960 path
- **Generic USB audio controls** - USB speaker and mic volume controls can be exposed in HA via MQTT
- **Realtime debug entities** - Realtime status, transcript, and last response can be surfaced in HA for testing

> The voice-assistant / audio / MQTT stack is inherited from the upstream project
> and slated to be rebuilt. The native Flutter dashboard is the active work.

---

## Repo Structure

```text
configure.sh                    # Main setup / install script for the Pi
mqtt-bridge.py                  # MQTT discovery + HA control entities
touch-scroll.py                 # Touch swipe -> scroll daemon
README.md                       # Main project documentation
LICENSE.txt                     # License

assistant/
  assistant_service.py          # Main assistant runtime service
  audio.py                      # Audio probing / capture / playback helpers
  config.py                     # Assistant env/config loading
  home_assistant.py             # HA REST service-call helper for Realtime tools
  memory.py                     # Local JSON memory store + MQTT sync payload support
  realtime.py                   # OpenAI Realtime session client/controller
  state.py                      # Local assistant state store
  wakeword.py                   # OpenWakeWord integration
  __init__.py

smart_display/
  lib/main.dart                 # Native Flutter display shell (main source)
  lib/dev_harness.dart          # Dev-only test harness (part of main.dart)
  shaders/liquid_glass.frag     # Liquid-glass refraction shader
  test/                         # Headless widget/unit tests

stl-files/
  body.stl                      # Main printed enclosure body
  frame.stl                     # Front frame
  grill.stl                     # Speaker grill
  README.md                     # STL / print notes
```

Note: the STL files are still in flux. The frame / grill fitment is being revised.

---

## Setup

### Prerequisites

- Fresh **Raspberry Pi OS 64-bit (Trixie)** install
- Pi connected to your network
- Home Assistant running with:
  - **MQTT integration** (Mosquitto) installed and configured
  - **Music Assistant 2.7+** (optional, for Sendspin)
  - **HACS installed** (optional)

### 1. Run the configuration script

Clone this repo onto the Pi and run the setup script as your normal user (not root):

```bash
git clone <your-repo-url> ~/smart-display
cd ~/smart-display
chmod +x configure.sh
./configure.sh
```

The script prompts you for:
- Device name (used as the HA device name and Music Assistant player name)
- Home Assistant URL
- Audio profile (`generic_usb` or `seeed_2mic_hat`)
- MQTT broker host, port, username, and password
- OpenAI API key
- OpenAI Realtime model
- OpenAI Realtime voice (default: `cedar`)
- Home Assistant long-lived token
- OpenWakeWord model and threshold
- Wake acknowledgement mode (`tone`, `file`, or `off`)
- For `generic_usb`: mic and speaker device names

Settings are saved after the first run - re-running the script will pre-fill all prompts with your previous values, so you only need to change what's different.
MQTT settings are stored in `/etc/smart-display/mqtt.env`, and assistant/runtime settings are stored in `/etc/smart-display/assistant.env`.
If you later point `OWW_MODEL` at a custom `.onnx` file in `/etc/smart-display/assistant.env`, rerunning `configure.sh` will preserve that live value instead of rolling back to an older saved wake-word setting.

The script installs and configures everything automatically, then offers to reboot when done.

### 2. Verify MQTT device

In HA go to **Settings -> Devices & Services -> MQTT** and look for your device name. It should appear automatically with core entities like:

- Assistant State (sensor)
- Mute (switch)
- Assistant Online (binary sensor)
- Assistant Audio Input / Output / Profile / Status (sensors)
- Assistant Trigger (button)
- Assistant Realtime Status (sensor)
- Assistant Last Transcript (sensor)
- Assistant Last Response (sensor)
- Brightness (number)

Volume / mic entities depend on the audio profile.

For `seeed_2mic_hat`:

- Voice Volume (number)
- Media Volume (number)
- Mic Sensitivity (number)

For `generic_usb`:

- Voice Volume (number)
- Speaker Volume (number)
- Mic Sensitivity (number)

If it doesn't appear, check that MQTT discovery is enabled in the MQTT integration settings.

---

## Services

All services are managed by systemd and start automatically on boot.

| Service | Description |
|---|---|
| `smart-display-assistant` | Assistant runtime baseline with local state, mute, and MQTT presence |
| `sendspin` | Music Assistant native player |
| `smart-display-audio-init` | Restores ALSA mixer state after seeed DKMS module loads (Seeed only) |
| `smart-display-mqtt` | MQTT bridge for HA auto-discovery |
| `smart-display-touch-scroll` | Translates touchscreen swipe gestures into scroll-wheel events |

Check all service status:
```bash
sudo systemctl status smart-display-assistant sendspin smart-display-audio-init \
  smart-display-mqtt smart-display-touch-scroll
```

---

## Audio Architecture

```text
Seeed / WM8960 profile:

Hardware: WM8960 (seeed2micvoicec)
           |
           v
      seeed_dmix         <- ALSA dmix (allows multiple simultaneous writers)
           |
      seeed_shared       <- plug over dmix (general use)
         /       \
   seeed_tts  seeed_media <- softvol streams (independent volume controls)
       |           |
 assistant   Sendspin
 (voice/TTS) (music)

Generic USB profile:

USB microphone  -> assistant capture / OpenWakeWord / Realtime
USB speaker     -> assistant playback / generic USB HA volume controls
```

Seeed volume controls:
- **TTS Volume** - `amixer -c seeed2micvoicec cset "name=TTS Volume" 80%`
- **Media Volume** - `amixer -c seeed2micvoicec cset "name=Media Volume" 80%`

Generic USB volume controls are handled via `pactl` in the MQTT bridge.

> **Note:** `pipewire-alsa` must not be installed on the Seeed / WM8960 path - it intercepts ALSA calls at the library level and prevents dmix from working. The setup script explicitly removes it. PipeWire remains available for microphone input.

---

## Customisation

### Mic sensitivity

Adjust the **Mic Sensitivity** slider in HA (the MQTT entity).

- On `seeed_2mic_hat`, this controls the WM8960 capture gain and persists across reboots.
- On `generic_usb`, this maps to the active USB source volume through `pactl`.

### Touch scroll speed

Edit `/usr/local/bin/touch-scroll.py` and adjust `TICKS_PER_SCREEN` (higher = faster scroll), then restart the service:

```bash
sudo systemctl restart smart-display-touch-scroll
```

### Custom wake word

OpenWakeWord model names are not magic phrases. A custom wake word like "Hey Felix" needs a trained `.onnx` model file.

Recommended path on the Pi (replace `~/smart-display` with wherever you cloned the repo):

```bash
mkdir -p ~/smart-display/models
cp hey_fe_lix.onnx ~/smart-display/models/hey_fe_lix.onnx
sudo sed -i "s|^OWW_MODEL=.*|OWW_MODEL=$HOME/smart-display/models/hey_fe_lix.onnx|" /etc/smart-display/assistant.env
sudo systemctl restart smart-display-assistant
```

Keep trained wake-word models out of git unless you intentionally want to publish them. The repo ignores `models/*.onnx` and `models/*.tflite`.

### Wake acknowledgement

After a wake-word detection, the assistant can play a short local acknowledgement before opening the Realtime session.

Modes:

- `WAKE_ACK_MODE=tone` plays a tiny local tone through the assistant speaker.
- `WAKE_ACK_MODE=file` plays a local audio file from `WAKE_ACK_FILE`.
- `WAKE_ACK_MODE=off` disables the acknowledgement.

Example:

```bash
sudo sed -i 's|^WAKE_ACK_MODE=.*|WAKE_ACK_MODE=tone|' /etc/smart-display/assistant.env
sudo systemctl restart smart-display-assistant
```

### Home Assistant voice actions

Realtime can call a generic Home Assistant service tool when `HOME_ASSISTANT_URL` and `HOME_ASSISTANT_TOKEN` are configured in `/etc/smart-display/assistant.env`.

Examples the assistant should be able to handle:

- "Turn on Jake's room lights"
- "Set my lamp to 30 percent"
- "Turn on movie mode" if that is an `input_boolean`, scene, or script
- "Set the helper to bedtime" if the entity and service are clear from the name/context

The tool calls HA services directly, so helpers work through their normal domains, such as `input_boolean.turn_on`, `input_number.set_value`, and `input_select.select_option`.

### Shared assistant memory

Memory is stored locally on each Pi as JSON:

```bash
~/.smart-display-assistant/memory/shared_memory.json
```

The same memory snapshot is also published as a retained MQTT message:

```text
smart-display/assistant/memory/shared
```

That lets multiple Pi displays sync basic shared facts without setting up a database. Realtime gets two tools:

- `remember_memory` for durable facts/preferences
- `recall_memory` for searching saved memory

This is intentionally simple. It is good for preferences like "Jake likes warm lights at night" or "the office lamp is called desk lamp," not large conversation history.

---

## Troubleshooting

**Audio settings don't persist after reboot**
On `seeed_2mic_hat`, the seeed DKMS module loads after `alsa-restore` runs. The `smart-display-audio-init` service handles this - check its status and logs. Speaker volume is also re-applied in `~/.config/labwc/autostart` as a safety net.

On `generic_usb`, confirm the selected USB devices still exist and that PipeWire is running.

**"No MCLK configured" in dmesg / aplay fails**
The seeed-voicecard DKMS module was built for a different kernel than the one currently running (common after `apt full-upgrade`). Fix:
```bash
sudo dkms build -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo dkms install -m seeed-voicecard -v 0.3 -k $(uname -r) --force
sudo reboot
```

**MQTT entities don't appear in HA**
- Check credentials in `/etc/smart-display/mqtt.env`
- Verify MQTT discovery is enabled in HA's MQTT integration settings
- Check `journalctl -u smart-display-mqtt -f` for connection errors

**Home Assistant gets slow only when the Pi is on**
- A live camera stream can keep load on HA the whole time the Pi is awake. Test services one at a time:

```bash
sudo systemctl stop smart-display-assistant
sudo systemctl stop smart-display-mqtt
```

If HA immediately recovers after stopping `smart-display-assistant`, check:

```bash
sudo journalctl -u smart-display-assistant -n 100 --no-pager
```

Repeated `api-key-missing`, `websocket-client-missing`, or OpenWakeWord startup errors mean the Pi was retrying assistant work in the background. The runtime now deduplicates repeated MQTT state publishes and backs off failed wake-word starts.

**Assistant state shows unavailable**
- Check `sudo systemctl status smart-display-assistant --no-pager`
- Check `sudo journalctl -u smart-display-assistant -n 80 --no-pager`

**Assistant runtime starts but Realtime does not respond**
- Check `/etc/smart-display/assistant.env` for `OPENAI_API_KEY` and Realtime settings
- Check `sudo journalctl -u smart-display-assistant -f`
- Test with the HA `Assistant Trigger` button before debugging wake word behavior

**Wake word does not trigger**
- Check `sudo journalctl -u smart-display-assistant -f`
- Confirm `OWW_MODEL` points to a real `.onnx` file if using a custom phrase
- Confirm `OWW_THRESHOLD`; lower it if the model misses you, raise it if it false-triggers
- Confirm the configured mic still appears in `arecord -L`

**`git pull` on the Pi says local files would be overwritten**
- Check `git status`
- If the repo has local drift, stash it before pulling:
```bash
git stash
git pull
```
- Then rerun `./configure.sh`

**Touch scrolling not working**
Check the daemon is running: `systemctl status smart-display-touch-scroll`
View logs: `journalctl -u smart-display-touch-scroll -f`

---

## License

> This project is licensed under the terms of the GNU General Public License v3.0. See the LICENSE.txt file for details.
