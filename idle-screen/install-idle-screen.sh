#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/.local/share/smart-display-idle"
CONFIG_DIR="$HOME/.config/smart-display-idle"
AUTOSTART_DIR="$HOME/.config/autostart"

command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required."
    exit 1
}

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$AUTOSTART_DIR"
cp "$SCRIPT_DIR/idle_screen.py" "$APP_DIR/"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.example.json" "$CONFIG_DIR/config.json"
    echo "Created $CONFIG_DIR/config.json"
    echo "Edit it with your latitude, longitude, and display name."
fi

cat > "$CONFIG_DIR/start-idle-screen.sh" <<EOF
#!/bin/bash
set -euo pipefail

APP_DIR="$APP_DIR"
CONFIG="$CONFIG_DIR/config.json"

cd "\$APP_DIR"
exec python3 "\$APP_DIR/idle_screen.py" --config "\$CONFIG"
EOF

chmod +x "$CONFIG_DIR/start-idle-screen.sh"

cat > "$AUTOSTART_DIR/smart-display-idle.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Smart Display Idle Screen
Exec=$CONFIG_DIR/start-idle-screen.sh
X-GNOME-Autostart-enabled=true
EOF

echo "Installed Smart Display Idle Screen."
echo "Config: $CONFIG_DIR/config.json"
echo "Autostart: $AUTOSTART_DIR/smart-display-idle.desktop"
echo "Run now with: $CONFIG_DIR/start-idle-screen.sh"
