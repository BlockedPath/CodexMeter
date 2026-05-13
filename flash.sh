#!/bin/bash
# Build and flash firmware to the M5Stack AtomS3.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${1:-/dev/cu.usbmodem101}"
ENVIRONMENT="${2:-m5stack_atoms3}"

echo "=== Flashing Codex Usage Tracker ==="
echo "Port: $PORT"
echo "Environment: $ENVIRONMENT"
echo ""

cd "$SCRIPT_DIR/firmware"
if [ -x "$HOME/.platformio/penv/bin/pio" ]; then
  PIO="$HOME/.platformio/penv/bin/pio"
elif [ -x "$SCRIPT_DIR/.venv/bin/pio" ]; then
  PIO="$SCRIPT_DIR/.venv/bin/pio"
elif command -v pio >/dev/null; then
  PIO="$(command -v pio)"
else
  echo "Error: PlatformIO CLI is required. Install it with:"
  echo "  python3 -m venv .venv"
  echo "  .venv/bin/python -m pip install platformio -r requirements.txt"
  exit 1
fi

"$PIO" run -e "$ENVIRONMENT" -t upload --upload-port "$PORT"

echo ""
echo "=== Done! ==="
