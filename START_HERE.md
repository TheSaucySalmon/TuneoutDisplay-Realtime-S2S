# START_HERE.md — Project context for any new Claude Code session

> **If you are a new Claude session: read this entire file first.** It tells you
> what this project is, how it's built, what's done, what's next, where the docs
> and tools live, and the rules you must follow. The user will say *"reference
> START_HERE.md for context before we continue."* This is that file.

---

## 1. What this project is

A **native Raspberry Pi 5 smart-display app**. A wall/desk touchscreen dashboard
backed by **Home Assistant**, with an iOS-26 "Liquid Glass" aesthetic (dark,
premium, glassy). The user can customize the whole UI **from within the running
app** (layout, cards, colors, background, glass style, per-card config).

**What it is NOT** (important — do not regress these):
- NOT a Chromium kiosk, NOT a web app, NOT a Lovelace dashboard.
- NOT an OS or a shell/compositor. It is a **Flutter app running fullscreen
  under the `labwc` Wayland compositor** on Raspberry Pi OS.

**End goals:** every feature configurable in-app; a real installer later
(system-setup `.deb` + in-app config screen); users can edit the code themselves.

**Aesthetic target:** iOS 26 glass buttons/cards + the look/process of the
`ui-ux-pro-max-skill` GitHub repo. Dark premium glass.

---

## 2. Where everything is

| Thing | Location |
|---|---|
| Repo (dev host) | `/home/jaker/Documents/TuneoutDisplay-main` |
| Repo (Raspberry Pi) | `~/TuneoutDisplay` (different path than dev host!) |
| GitHub | `TheSaucySalmon/TuneoutDisplay-Realtime-S2S`, branch `main` |
| Git identity | name `TheSaucySalmon`, email `jrhk1317@gmail.com` |
| **The app** | `smart_display/` — Flutter app, **everything is in `lib/main.dart`** (~3970 lines, single file by design) |
| Liquid-glass shader | `smart_display/shaders/liquid_glass.frag` (custom GLSL) |
| Setup/installer script | `configure.sh` (installs Flutter SDK to `~/flutter`, build deps, writes `ha.json`, sets labwc autostart) |
| Voice assistant (Python) | `assistant/` (OpenAI Realtime S2S) + `mqtt-bridge.py` + `touch-scroll.py` |
| Flutter Linux runner | `smart_display/linux/` (GTK embedder) |
| Project docs | `README.md`, `ha-configuration.md`, `OPENAI-REALTIME.md` |
| 3D-print files | `stl-files/` |

### Local reference material (gitignored — local only)
- **Home Assistant docs**: `Home Assistant Docs/` — full Markdown clones of
  `home-assistant.io` (`user-docs/`) and `developers.home-assistant`
  (`dev-docs/`). See `Home Assistant Docs/INDEX.md` for the navigation map.
  **GREP THESE BEFORE WEBSEARCHING** for any HA specifics.
- **Knowledge graph**: `graphify-out/` (graph.json, GRAPH_REPORT.md, graph.html).
- **Obsidian vault**: `/home/jaker/Documents/TuneoutDisplay-Vault` (sibling of repo).
- **Auto-memory**: `/home/jaker/.claude/projects/-home-jaker-Documents-TuneoutDisplay-main/memory/`
  — `MEMORY.md` is the index; individual `.md` files hold one fact each.

### Runtime config (on the device, NOT in the repo)
- `~/.config/smart-display/ha.json` — HA URL + long-lived token (written by `configure.sh`). **The HA key is already set on the Pi.**
- `~/.config/smart-display/theme.json` — persisted `AppConfig` (theme).
- `~/.config/smart-display/layout.json` — persisted `AppLayout` (the cards).

---

## 3. How to build, run, deploy

**Build on the dev host** (Flutter SDK is at `~/flutter`):
```bash
cd smart_display && export PATH="$PATH:$HOME/flutter/bin" \
  && flutter analyze lib/main.dart && flutter build linux --release
```
> Note: `flutter` working dir resets between tool calls — always `cd smart_display`
> and re-export PATH in the same command.

**Deploy to the Pi** (one-liner the user uses):
```bash
cd ~/TuneoutDisplay && git stash && git pull && cd smart_display && flutter build linux --release && sudo reboot
```
(`git stash` is usually needed — local build/config churn blocks the pull.
`sudo reboot` relaunches under labwc autostart.)

---

## 4. App architecture (`smart_display/lib/main.dart`)

`main()` loads the glass shader (`glassProgram`), `AppConfig.load()`, and
`AppLayout.load()`, then runs `SmartDisplayApp`.

**Widget/scope tree:** `ConfigScope > LayoutScope > MaterialApp(home: RootShell)`.
- `ConfigScope` (AppConfig) and `LayoutScope` (AppLayout) are **above
  MaterialApp**, so modal bottom sheets inherit them automatically.
- Inside `RootShell` (below the Navigator):
  `HaScope > EntityScope > WeatherScope > GlassClock > BgTextureScope > Listener
  > MouseRegion(cursor: none) > Scaffold > Stack[...]`.
- **CRITICAL gotcha:** `HaScope`, `EntityScope`, `WeatherScope`, `GlassClock`,
  `BgTextureScope` live *inside* RootShell, so **modal bottom sheets do NOT
  inherit them** — you must **re-inject** them in any `showModalBottomSheet`
  builder (capture `X.of(context)` before showing, wrap the sheet child). See
  `_showCardSettings`, `_showEntityPicker`, `_showMoreInfo` for the pattern.

**Key scopes / state objects:**
- `AppConfig` (theme.json): `bg` (glow/waves/solid), `cardStyle`
  (liquidGlass/frosted/solid/outline), `intensity`, `cornerRadius`, `accent`,
  `cardColor`, `bgColor`.
- `AppLayout` (layout.json): `List<CardSpec>` on a **4×4 grid** (`kGridCols/Rows`).
- `CardSpec`: `id, kind, entityId, col, row, w, h` + per-card overrides:
  `style, color, name, showName, showState, showIcon, vertical, tap`
  (more-info/toggle/none), camera `fit`+`aspect`, weather
  `showCurrent/showForecast/forecastType/roundTemp`, calendar `initialView`.
- `CardKind`: `weather, camera, calendar, haStatus, entity`.
- `CardOverride` (InheritedWidget): carries per-card style/color into
  `LiquidGlass`/`_EntityCard` via context.
- `HaClient`: REST (`/api/states`, `/api/states/<id>`,
  `/api/services/<domain>/<service>` with optional data map, `/api/camera_proxy/<id>`)
  + WebSocket (`/api/websocket`). Reads `ha.json`.
- `EntityCatalog`: REST snapshot + live WS updates (`state_changed`,
  `entity_registry_updated`). The user's instance has ~**384 entities**.
- `WeatherController`: Open-Meteo, **hardcoded Bally, PA** (`kLat 40.4015`,
  `kLon -75.5874`). (Could be auto-set from HA `/api/config` later.)
- `FrameClock`: caps animation to `kTargetFps = 30`; **stops while idle**.
- `BrightnessController`: 5% from 22:00–06:00, 100% otherwise; writes
  `/sys/class/backlight`.

**Liquid glass:** custom GLSL shader (the `liquid_glass_renderer` package is
Impeller-only / no Linux). Performance trick: the background is rendered once per
frame to a low-res `ui.Image` snapshot that the shader samples (`BgTexture`).

**Idle screen:** static frozen aurora; `FrameClock` pauses entirely while idle
(idle is shown 90%+ of the time → big thermal win). `ClockText` keeps its own
timer so the clock stays live.

### The layout editor (HA-dashboard-style)
- **Enter edit mode:** swipe up from the bottom 30% **and hold ~2s** (radial
  ring fills). Exit via **Done**.
- Edit mode insets the grid **66px** from the top so top-row cards aren't hidden
  behind the edit bar.
- Each card in edit mode: **gear (top-left) → settings**, **✕ (top-right) →
  delete**. **Long-press to drag** (grid-snap). *Do not use a pan recognizer for
  drag — it steals taps on the touchscreen; long-press is intentional.*
- `_EditBar` (top): Editing · 🎨 theme · ＋ add · Done.
- **Card editor** (`_CardEditor`): tabbed **Config / Layout / Style** + a **live
  preview** of the real card. Per-kind config mirrors HA's GUI.
- **Entity picker** (`_EntityPicker`): searchable list over the live catalog.
- **On-screen keyboard** (`OnScreenKeyboard`): the Flutter Linux/GTK embedder
  does NOT summon a system keyboard and the Pi has no physical one, so text
  input is driven by this in-app QWERTY (entity search + `_showTextInput`).
- **More-info** (`_MoreInfoSheet`): per-domain controls (see §6).

---

## 5. Thermal constraints (read before adding anything GPU-heavy)
- Pi 5 **overheats fanless**. An **Active Cooler was ordered, not yet installed**.
- The static idle screen + clock-pause dropped temps a lot. Active dashboard
  sits ~**75°C** (under the 80°C soft throttle) — acceptable for now.
- **SAFE to build now (low GPU):** UI work — layout editor, entity controls,
  more HA wiring, the AI speaking bar.
- **DEFER until the cooler arrives:** the live camera video stream (continuous
  decode) and bumping `kTargetFps` 30→60. Both are sustained-load.

---

## 6. What's been done (status)

Pivoted from a Tkinter prototype to Flutter. Built: liquid-glass shader, idle
screen, glass dashboard, in-app customization/edit mode, theme panel, swipe nav,
brightness rule, hidden cursor. HA integration: live 384-entity catalog,
snapshot camera tile (any HA camera).

**Layout editor** (data-driven 4×4 grid → `layout.json`): hold-to-edit, drag,
entity picker, per-card settings, and a tabbed HA-style card editor with live
preview. Per-card-type config (weather/calendar/ha-status/entity/camera).

**Entity control — Phase 1 (done):** `callService` sends data payloads; icons for
all domains; the more-info sheet renders **per-domain controls**: light
brightness, fan speed, climate (hvac modes + target temp), cover
(open/stop/close + position), media (transport + volume), lock, number/
input_number slider, select/input_select options, input_text edit (via OSK),
counter, timer, and press/run/activate/trigger for button/script/scene/
automation. Toggleables get a header on/off pill.

Fixes along the way: card tap was dead in edit mode (pan vs tap) → long-press
drag + gear button; top-row cards undeletable (edit-bar occlusion) → grid inset;
no keyboard for search → in-app OnScreenKeyboard.

Latest commits (newest first): see `git log`. As of this writing the head is
`8f7e18f` (gitignore HA docs). The full HA documentation was cloned locally.

---

## 7. What's next (open work)

- **Entity control — Phase 2:** vacuum, alarm_control_panel, valve, water_heater,
  humidifier, input_datetime/date/time **pickers**, **light color** (temp/RGB),
  media **source** selection.
- **Real HA calendar:** replace the placeholder using `GET /api/calendars` +
  `GET /api/calendars/<id>?start&end` (no CalDAV needed when HA has the
  calendar). Endpoint confirmed in the docs.
- **Real weather forecast:** `weather.get_forecasts?return_response` (daily/
  hourly) → drives the deferred forecast view; weather card config already has
  the options saved.
- **Sensor history/graphs:** `/api/history/period` for bar-gauge / trend tiles.
- **Auto location + units:** `/api/config` returns lat/long/unit_system/time_zone
  → could replace the hardcoded Bally PA coords.
- Grid ↔ free-placement toggle (currently grid-snap only).
- "Move some buttons around" — an edit-bar tweak the user mentioned; needs them
  to specify exactly what moves where.
- AI "speaking" bar (small transient idle animation; thermally safe).
- Real installer (`.deb` + in-app config). Live camera stream + 60fps (post-cooler).

---

## 8. Working rules — FOLLOW THESE (the user cares)

1. **Commit style:** do **NOT** add a `Co-Authored-By: Claude` trailer to commits
   or PRs. (User rejected it explicitly.)
2. **Never push graphify or Obsidian data to GitHub.** `graphify-out/`,
   `.claude/`, and `Home Assistant Docs/` are gitignored — keep it that way.
3. **On EVERY git push, refresh the knowledge graph + Obsidian vault locally**
   (then they stay local, never committed):
   - `/graphify --update` (incremental). When detecting changes, **filter out
     `/.dart_tool/` and `/build/`** paths (they churn on every Flutter build).
     For code-only changes you can run AST-only (skip semantic subagents).
   - Re-export the vault: the export does NOT prune deleted nodes, so **delete
     the vault's `*.md`/`*.canvas` first (keep `.obsidian/`)** then
     `graphify export obsidian --dir /home/jaker/Documents/TuneoutDisplay-Vault`.
   - This can't be a pure git hook (semantic extraction needs the LLM session) —
     you run it as part of the push routine.
4. **Reference the local HA docs** (`Home Assistant Docs/`) before websearching.
5. The HA long-lived token is **already configured on the Pi** — don't worry
   about provisioning it.
6. After each change: `flutter analyze` + `flutter build linux --release` must
   pass before committing.

---

## 9. Fast orientation checklist for a new session
1. Read this file.
2. Skim `MEMORY.md` (auto-loaded) — it indexes per-fact memory files.
3. For code: open `smart_display/lib/main.dart` (single source file).
4. For HA specifics: `Home Assistant Docs/INDEX.md` → grep `Home Assistant Docs/`.
5. For architecture overview: `graphify-out/GRAPH_REPORT.md`.
6. Check `git log --oneline` for the latest state.
