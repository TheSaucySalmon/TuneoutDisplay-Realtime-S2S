# Home Assistant Configuration - Smart Display

This file documents the current custom card setup for the assistant runtime in this repo.

## 1. Install the card resource

1. Copy [smart-display-card.js](/c:/Users/jaker/Documents/FelixHomeAI/TuneoutDisplay-main/lovelace/smart-display-card.js) to `/config/www/smart-display-card.js` on your Home Assistant instance.
2. In Home Assistant go to `Settings -> Dashboards -> Resources`.
3. Add:
   - URL: `/local/smart-display-card.js`
   - Type: `JavaScript module`
4. Hard refresh the browser.

## 2. Current runtime entity pattern

The current assistant runtime publishes entities like:

- `sensor.YOUR_DEVICE_assistant_state`
- `switch.YOUR_DEVICE_mute`
- `number.YOUR_DEVICE_brightness`
- `sensor.YOUR_DEVICE_assistant_audio_input`
- `sensor.YOUR_DEVICE_assistant_audio_output`
- `sensor.YOUR_DEVICE_assistant_audio_profile`

Some older or future setups may also expose:

- `assist_satellite.YOUR_DEVICE`
- `number.YOUR_DEVICE_tts_volume`
- `number.YOUR_DEVICE_media_volume`
- `number.YOUR_DEVICE_mic_gain`

The updated card supports both styles.

## 3. Recommended card config for the current baseline

For your current `Jake's Room` setup, start with:

```yaml
type: custom:smart-display-card
name: Jake's Room
state_entity: sensor.jakes_room_assistant_state
brightness_entity: number.jakes_room_brightness
mute_entity: switch.jakes_room_mute
```

This gives you:

- assistant status chip
- mute toggle via chip tap
- brightness slider

## 4. Full card config when more entities exist

If your setup later exposes voice/media/mic controls, use:

```yaml
type: custom:smart-display-card
name: Jake's Room
state_entity: sensor.jakes_room_assistant_state
brightness_entity: number.jakes_room_brightness
mute_entity: switch.jakes_room_mute
tts_volume_entity: number.jakes_room_tts_volume
media_volume_entity: number.jakes_room_media_volume
mic_gain_entity: number.jakes_room_mic_gain
```

If you are using an older Assist Satellite style entity instead of the assistant sensor, this also works:

```yaml
type: custom:smart-display-card
name: Jake's Room
satellite_entity: assist_satellite.jakes_room
brightness_entity: number.jakes_room_brightness
mute_entity: switch.jakes_room_mute
tts_volume_entity: number.jakes_room_tts_volume
media_volume_entity: number.jakes_room_media_volume
mic_gain_entity: number.jakes_room_mic_gain
```

## 5. Notes

- `state_entity` is preferred for the current assistant runtime in this repo.
- `satellite_entity` is kept for backward compatibility.
- Sliders only render when their entity is configured.
- If brightness does not physically change yet, check your display backlight wiring later.
