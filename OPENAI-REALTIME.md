# OPENAI-REALTIME.md

Reference notes for implementing OpenAI Realtime speech-to-speech in this smart display project.

## Goal

Replace the old assistant-specific notes with a clear implementation target for:

- wake word or tap-to-talk activation
- microphone capture from the Pi audio stack
- OpenAI Realtime session management
- speech-to-speech playback on the display device
- Home Assistant state + MQTT exposure for UI/status

## Current repo status

What already exists:

- Raspberry Pi kiosk / smart display shell
- MQTT bridge for Home Assistant entities
- custom Lovelace smart display card
- audio initialization and volume controls
- touch scrolling and display boot flow
- baseline assistant service with local state, mute, and presence

What is not finished yet:

- OpenWakeWord activation flow
- OpenAI Realtime websocket/session loop
- streaming microphone input to Realtime
- streaming model audio output back to speakers
- interruption / barge-in behavior
- conversation lifecycle handling

## Implementation target

The desired runtime should look like:

1. Device is idle and exposed to Home Assistant as `idle` or `muted`
2. Wake word or UI action starts a Realtime session
3. Microphone audio is streamed to OpenAI Realtime
4. Realtime returns audio output and events
5. Audio plays through the TTS/assistant channel on the Pi
6. State is reflected in Home Assistant:
   - `idle`
   - `listening`
   - `processing`
   - `responding`
   - `muted`
7. Session ends cleanly and device returns to idle

## Proposed local architecture

```text
Mic input
  -> wake word / trigger gate
  -> assistant runtime
  -> OpenAI Realtime session
  -> returned audio stream
  -> local playback on seeed_tts
  -> MQTT / HA state updates
```

## Audio expectations

- Keep assistant / speech playback on `seeed_tts`
- Keep media playback on `seeed_media`
- Preserve separate HA sliders for assistant volume and media volume
- Do not reintroduce `pipewire-alsa`

## Home Assistant expectations

Useful entities to preserve or expose:

- `sensor.*_assistant_state`
- `switch.*_mute`
- `number.*_brightness`
- `number.*_tts_volume`
- `number.*_media_volume`
- `number.*_mic_gain`

Optional later:

- `sensor.*_last_transcript`
- `sensor.*_last_intent`
- `binary_sensor.*_listening`

## Runtime notes

- Realtime model default in this repo is currently `gpt-realtime`
- Session management should be isolated from kiosk/browser logic
- UI should continue working even if Realtime is offline
- Mute state should hard-block mic capture and session start
- Interruptions should stop current playback before new response audio starts

## Suggested implementation phases

### Phase 1

- establish authenticated Realtime connection
- stream mic audio in
- receive audio out
- play returned audio locally

### Phase 2

- add wake word gating
- add interruption behavior
- improve status transitions in HA

### Phase 3

- expose transcript/debug sensors
- add better failure handling and reconnect logic
- add optional tool/function calling against Home Assistant

## Files likely involved

- `assistant/assistant_service.py`
- `assistant/audio.py`
- `assistant/state.py`
- `assistant/config.py`
- `mqtt-bridge.py`
- `configure.sh`

## Documentation rule

This file should stay implementation-focused and OpenAI-specific.
Do not reintroduce Claude-specific workflow notes here.
