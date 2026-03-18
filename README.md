# TuneoutDisplay

## Credits

This project is based on [TuneoutDisplay](https://github.com/zmsaunders/TuneoutDisplay) by [zmsaunders](https://github.com/zmsaunders).

My version keeps the Raspberry Pi smart display / Home Assistant integration concept, but replaces the original voice assistant approach with OpenAI GPT-Realtime speech-to-speech. The original script I made was just an injector script for chromium, which kinda sucked. Also, my hardware setup looked like a cursed image, which sucked as well. Surprisingly, I came across zmsaunders post on the Home Assistant subreddit, and his work solved everything except for the gpt-realtime speech-to-speech issue. 

I don't intend for anyone to see this project anyways, I'm just an idiot that doesn't know how to use GitHub and decided to click some buttons, and now I'm here. Could I have made a private copy of this repo for myself? Probably. Do I know how? Nope. I already did pushes/pulls with this repo, so there's no going back (I'm lazy). If anyone is reading this, I'm sorry lmao.

## Full Disclosure

Just like the original author, I only work on this project in my spare time. I'm also not the world greatest programmer, so I used Codex to help with the recreation of this project. I'm pretty new to Raspberry Pi's, so I'm still learning everything about them. I also am very new to Linux, since I was raised using Windows. I apologize if anything in here is worded incorrectly.

---

## Hardware

| Component | Details |
|---|---|
| SBC | Raspberry Pi 5 (4GB or 8GB of RAM) |
| Microphone / Audio | KEYESTUDIO ReSpeaker 2-Mic Pi HAT (WM8960 codec) |
| Display | Raspberry Pi Official 7" DSI Touchscreen OR 7 Inch Touchscreen IPS DSI Display by Hosyond (Amazon) |
| Speaker | 3W 8 ohm |
| OS | Raspberry Pi OS 64-bit (Trixie / Debian 13), kernel 6.12.x |
| Compositor | labwc (Wayland) |

I'm not entirely sure if it really matters what version of the Raspberry Pi is used. A Pi 4B was used originally, I just happened to buy a Pi 5 when I started my project. I guess we'll find out. Like I said previously, I'm still pretty new to the Raspberry Pi world, so I'm not familiar with all of it yet.

---

## Features

- **HA Lovelace kiosk** - Chromium in kiosk mode, launches automatically after boot and waits for HA to be reachable before opening
- **Voice-runtime ready shell** - Kiosk, audio, MQTT, and touch pieces are set up independently so you can plug in your own assistant runtime
- **Music Assistant playback** - Sendspin native player; appears automatically in MA 2.7+
- **MQTT auto-discovery** - Device registers itself in HA with Voice Volume, Media Volume, Brightness, and Mic Sensitivity entities - no YAML needed
- **Touch scrolling** - Daemon translates touchscreen swipe gestures into scroll-wheel events for labwc/Wayland
- **Independent volume channels** - TTS/voice and media are separate ALSA softvol streams, each with its own HA slider
- **Per-device mic tuning** - Mic sensitivity is adjustable from HA, persists across reboots, useful for different room sizes and placements

---

## Repo Structure

```text
configure.sh              # Main setup script - run once on a fresh install (idempotent, re-runnable)
mqtt-bridge.py            # MQTT auto-discovery bridge for HA device entities
touch-scroll.py           # Touch-to-scroll daemon (uinput virtual device)
lovelace/
  smart-display-card.js   # Custom Lovelace card (copy to HA /config/www/)
ha-configuration.md       # Full HA config reference
CLAUDE.md                 # Technical reference for AI-assisted development
```

---

## Setup

### Prerequisites

- Fresh **Raspberry Pi OS 64-bit (Trixie)** install
- Pi connected to your network
- Home Assistant running with:
  - **MQTT integration** (Mosquitto) installed and configured
  - **Music Assistant 2.7+** (optional, for Sendspin)

### 1. Run the configuration script

Clone this repo onto the Pi and run the setup script as your normal user (not root):

```bash
git clone https://github.com/YOUR_USERNAME/TuneoutDisplay.git
cd TuneoutDisplay
chmod +x configure.sh
./configure.sh
```

The script prompts you for:
- Device name (used as the HA device name and Music Assistant player name)
- Home Assistant URL
- Lovelace kiosk URL (optional - skip to set up kiosk manually later)
- MQTT broker host, port, username, and password
- assistant runtime settings such as OpenAI API key, HA token, activation model, and realtime model

Settings are saved after the first run - re-running the script will pre-fill all prompts with your previous values, so you only need to change what's different.
MQTT settings are stored in `/etc/smart-display/mqtt.env`, and assistant/runtime settings are stored in `/etc/smart-display/assistant.env`.

The script installs and configures everything automatically, then offers to reboot when done.

### 2. Verify MQTT device

In HA go to **Settings -> Devices & Services -> MQTT** and look for your device name. It should appear automatically with these entities:

- Voice Volume (number)
- Media Volume (number)
- Brightness (number)
- Mic Sensitivity (number)

If it doesn't appear, check that MQTT discovery is enabled in the MQTT integration settings.

### 3. Add the Lovelace control card (optional)

The custom card gives you volume and brightness controls in any HA dashboard. Its status and mute chip can be preserved later by exposing compatible entities from your assistant runtime.

1. Copy `lovelace/smart-display-card.js` to `/config/www/` on your HA instance
2. In HA go to **Settings -> Dashboards -> Resources -> Add**
   - URL: `/local/smart-display-card.js`
   - Type: JavaScript module
3. Add the card to a dashboard:

```yaml
type: custom:smart-display-card
name: My Display
satellite_entity: assist_satellite.YOUR_DEVICE
tts_volume_entity: number.YOUR_DEVICE_tts_volume
media_volume_entity: number.YOUR_DEVICE_media_volume
brightness_entity: number.YOUR_DEVICE_brightness
mute_entity: switch.YOUR_DEVICE_mute        # optional - enables chip tap-to-mute
mic_gain_entity: number.YOUR_DEVICE_mic_gain  # optional
```

Find your exact entity IDs under **Developer Tools -> States** and search for your device name. The number entities above come from the MQTT bridge. The status and mute entities are not created by the current base setup and should be supplied later by your assistant runtime if you want to keep that behavior.

### 4. Add swipe navigation between dashboard views (optional)

Install **Swipe Navigation** from HACS (Frontend section), then add `/hacsfiles/swipe-navigation/swipe-navigation.js` as a Lovelace resource. No card config needed - it activates automatically on all views.

---

## Services

All services are managed by systemd and start automatically on boot.

| Service | Description |
|---|---|
| `smart-display-assistant` | Assistant runtime baseline with local state, mute, and MQTT presence |
| `sendspin` | Music Assistant native player |
| `smart-display-audio-init` | Restores ALSA mixer state after seeed DKMS module loads |
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
```

Volume controls:
- **TTS Volume** - `amixer -c seeed2micvoicec cset "name=TTS Volume" 80%`
- **Media Volume** - `amixer -c seeed2micvoicec cset "name=Media Volume" 80%`

> **Note:** `pipewire-alsa` must not be installed - it intercepts ALSA calls at the library level and prevents dmix from working. The setup script explicitly removes it. PipeWire remains available for microphone input when you add your own assistant runtime.

---

## Customisation

### Mic sensitivity

Adjust the **Mic Sensitivity** slider in HA (the MQTT entity). Higher values boost the microphone preamplifier for better far-field pickup. The value persists across reboots. Default is 63% (0 dB on the WM8960 Capture PGA).

### Touch scroll speed

Edit `/usr/local/bin/touch-scroll.py` and adjust `TICKS_PER_SCREEN` (higher = faster scroll), then restart the service:

```bash
sudo systemctl restart smart-display-touch-scroll
```

### Kiosk URL

Re-run `./configure.sh` and enter a new kiosk URL at the prompt, or edit `~/.config/labwc/autostart` directly.

---

## Troubleshooting

**Audio settings don't persist after reboot**
The seeed DKMS module loads after `alsa-restore` runs. The `smart-display-audio-init` service handles this - check its status and logs. Speaker volume is also re-applied in `~/.config/labwc/autostart` as a safety net.

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

**Assistant runtime is online but not conversational yet**
The baseline assistant service handles local state, mute, and MQTT presence. OpenWakeWord and OpenAI Realtime session handling are still the next implementation steps.

**Touch scrolling not working**
Check the daemon is running: `systemctl status smart-display-touch-scroll`
View logs: `journalctl -u smart-display-touch-scroll -f`

---

# License

> This project is licensed under the terms of the GNU General Public License v3.0. See the LICENSE.txt file for details.
