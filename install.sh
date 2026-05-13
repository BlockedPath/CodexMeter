#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="codex-usage-daemon"
DAEMON_BIN="$SCRIPT_DIR/daemon/codex-usage-daemon.py"

echo "=== CodexMeter - Install ==="
echo ""

if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
  PYTHON="$SCRIPT_DIR/.venv/bin/python"
elif [ -x "$HOME/.platformio/penv/bin/python" ]; then
  PYTHON="$HOME/.platformio/penv/bin/python"
elif command -v python3 >/dev/null; then
  PYTHON="$(command -v python3)"
else
  echo "Error: python3 is required"
  exit 1
fi

"$PYTHON" -m pip install -r "$SCRIPT_DIR/requirements.txt"

CONFIG_DIR="$HOME/.config/codexmeter"
ENV_FILE="$CONFIG_DIR/env"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<ENV
# CodexMeter daemon settings.
# OPENAI_ADMIN_KEY=sk-admin-...
CODEXMETER_DAILY_BUDGET_USD=10
CODEXMETER_WEEKLY_BUDGET_USD=50
CODEXMETER_TRANSPORT=serial
ENV
  chmod 600 "$ENV_FILE"
fi

case "$(uname -s)" in
  Darwin)
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_FILE="$PLIST_DIR/com.justin.codexmeter.plist"
    mkdir -p "$PLIST_DIR"
    cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.justin.codexmeter</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$DAEMON_BIN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/codexmeter.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/codexmeter.err.log</string>
</dict>
</plist>
PLIST
    launchctl unload "$PLIST_FILE" >/dev/null 2>&1 || true
    launchctl load "$PLIST_FILE"
    echo "Installed LaunchAgent: $PLIST_FILE"
    echo "Logs: $HOME/Library/Logs/codexmeter.log"
    ;;
  Linux)
    USER_SERVICE_DIR="$HOME/.config/systemd/user"
    SERVICE_FILE="$SCRIPT_DIR/daemon/$SERVICE_NAME.service"
    mkdir -p "$USER_SERVICE_DIR"
    sed "s|DAEMON_PATH|${DAEMON_BIN}|g" "$SERVICE_FILE" > "$USER_SERVICE_DIR/$SERVICE_NAME.service"
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    systemctl --user restart "$SERVICE_NAME"
    echo "Installed systemd user service: $SERVICE_NAME"
    ;;
  *)
    echo "Unsupported OS. Run manually with:"
    echo "  $DAEMON_BIN"
    ;;
esac

echo ""
echo "CodexMeter will use your logged-in Codex/ChatGPT OAuth usage from ~/.codex/auth.json."
echo "Optional: set OPENAI_ADMIN_KEY in $ENV_FILE only if you want OpenAI API org cost tracking fallback."
