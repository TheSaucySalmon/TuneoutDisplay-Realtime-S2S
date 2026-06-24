# Home Assistant Configuration - Smart Display

How the smart display integrates with Home Assistant. There is no Lovelace card
or dashboard to install — the native Flutter app (`smart_display/`) is the UI and
talks to HA directly.

## 1. How the display connects to HA

Two paths, both set up by `configure.sh`:

- **MQTT auto-discovery** — `mqtt-bridge.py` registers this device in HA over MQTT
  and publishes its control/status entities (no YAML needed). See section 2.
- **Direct HA API** — the Flutter app reads a long-lived token + HA URL from
  `~/.config/smart-display/ha.json` (written by `configure.sh`) and uses the HA
  REST + WebSocket API to pull all entities live and call services.

## 2. Runtime entity pattern

The assistant runtime / MQTT bridge publishes entities like:

- `sensor.YOUR_DEVICE_assistant_state`
- `switch.YOUR_DEVICE_mute`
- `number.YOUR_DEVICE_brightness`
- `sensor.YOUR_DEVICE_assistant_audio_input`
- `sensor.YOUR_DEVICE_assistant_audio_output`
- `sensor.YOUR_DEVICE_assistant_audio_profile`

Depending on the audio profile, volume / mic entities also appear:

- `number.YOUR_DEVICE_tts_volume`
- `number.YOUR_DEVICE_media_volume` (or speaker volume on `generic_usb`)
- `number.YOUR_DEVICE_mic_gain`

Find the exact IDs in HA under **Settings -> Devices & Services -> MQTT ->
YOUR_DEVICE**, or **Developer Tools -> States**.

## 3. Notes

- The display fetches every HA entity over the API, so anything you add in HA
  becomes available to place on the screen — no per-entity config here.
- If brightness does not physically change, check the display backlight wiring
  and that the user is in the `video` group (the udev rule `configure.sh`
  installs grants this).
