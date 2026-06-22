#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/smart-display-idle"
CONFIG_DIR="$HOME/.config/smart-display-idle"
AUTOSTART_DIR="$HOME/.config/autostart"
LABWC_DIR="$HOME/.config/labwc"

command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required."
    exit 1
}

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$AUTOSTART_DIR" "$LABWC_DIR"
cp "$SCRIPT_DIR/idle_screen.py" "$APP_DIR/"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
    echo "Created $CONFIG_DIR/config.json"
    echo "Edit it with your latitude, longitude, and display name."
fi

python3 - "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json" <<'PY'
import json
import sys
from pathlib import Path

defaults_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
defaults = json.loads(defaults_path.read_text(encoding="utf-8"))
config = json.loads(config_path.read_text(encoding="utf-8"))

for key, value in defaults.items():
    config.setdefault(key, value)

if config.get("stateFile") == "~/.config/smart-display-idle/state.json":
    config["stateFile"] = "~/.smart-display-assistant/state.json"

config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY

cat > "$CONFIG_DIR/start-idle-screen.sh" <<EOF
#!/bin/bash
set -euo pipefail

APP_DIR="$APP_DIR"
CONFIG="$CONFIG_DIR/config.json"

cd "\$APP_DIR"
exec python3 "\$APP_DIR/idle_screen.py" --config "\$CONFIG"
EOF

chmod +x "$CONFIG_DIR/start-idle-screen.sh"

cat > "$CONFIG_DIR/show-idle-screen.sh" <<EOF
#!/bin/bash
set -euo pipefail

if pgrep -f "$APP_DIR/idle_screen.py" >/dev/null 2>&1; then
    exit 0
fi

DISPLAY="\${DISPLAY:-:0}"
XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DISPLAY XDG_RUNTIME_DIR

"$CONFIG_DIR/start-idle-screen.sh" >/tmp/smart-display-idle.log 2>&1 &
EOF

cat > "$CONFIG_DIR/hide-idle-screen.sh" <<EOF
#!/bin/bash
set -euo pipefail

pkill -f "$APP_DIR/idle_screen.py" >/dev/null 2>&1 || true
EOF

cat > "$CONFIG_DIR/idle-watch.sh" <<EOF
#!/bin/bash
set -euo pipefail

CONFIG="$CONFIG_DIR/config.json"
LOCK="$CONFIG_DIR/idle-watch.lock"
exec 9>"\$LOCK"
flock -n 9 || exit 0

TIMEOUT=\$(python3 - <<PY
import json
from pathlib import Path
path = Path("$CONFIG_DIR/config.json")
try:
    print(max(5, int(json.loads(path.read_text()).get("idleTimeoutSeconds", 60))))
except Exception:
    print(60)
PY
)

if command -v swayidle >/dev/null 2>&1; then
    exec swayidle -w \\
        timeout "\$TIMEOUT" "$CONFIG_DIR/show-idle-screen.sh" \\
        resume "$CONFIG_DIR/hide-idle-screen.sh"
fi

echo "swayidle is required for inactivity-triggered idle mode on Raspberry Pi OS labwc." >&2
echo "Install it with: sudo apt install swayidle" >&2
exec "$CONFIG_DIR/show-idle-screen.sh"
EOF

chmod +x "$CONFIG_DIR/show-idle-screen.sh" "$CONFIG_DIR/hide-idle-screen.sh" "$CONFIG_DIR/idle-watch.sh"

cat > "$AUTOSTART_DIR/smart-display-idle.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Smart Display Idle Watcher
Exec=$CONFIG_DIR/idle-watch.sh
X-GNOME-Autostart-enabled=true
EOF

if [ ! -f "$LABWC_DIR/autostart" ] || ! grep -q "smart-display-idle/idle-watch.sh" "$LABWC_DIR/autostart"; then
    cat >> "$LABWC_DIR/autostart" <<EOF

# Smart Display idle screen watcher
"$CONFIG_DIR/idle-watch.sh" &
EOF
    chmod +x "$LABWC_DIR/autostart"
fi

echo "Installed Smart Display Idle Screen."
echo "Config: $CONFIG_DIR/config.json"
echo "Autostart: $AUTOSTART_DIR/smart-display-idle.desktop and $LABWC_DIR/autostart"
echo "Idle watcher: $CONFIG_DIR/idle-watch.sh"
echo "Install swayidle if needed: sudo apt install swayidle"
echo "Force show now: $CONFIG_DIR/show-idle-screen.sh"
