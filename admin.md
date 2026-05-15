# CodexMeter Admin Runbook

This file is the operator guide for building, flashing, running, and debugging
CodexMeter in the real environment.

## What This Project Runs

CodexMeter is a small desk display for Codex/OpenAI usage. It has two runtime
parts:

- AtomS3 firmware in `firmware/`, built with PlatformIO for
  `m5stack_atoms3`.
- A host daemon in `daemon/codex-usage-daemon.py` that reads usage/activity
  from the local machine and pushes compact JSON to the AtomS3.

The supported hardware target is the M5Stack AtomS3 ESP32-S3. USB serial is the
normal transport. BLE is still implemented and useful as a fallback/debug path,
but serial is the primary desk-prototype path.

## Fresh Setup

Create the Python environment and install the daemon plus PlatformIO tooling:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install platformio -r requirements.txt
```

If a global PlatformIO is already installed, the helper scripts may use it. On
this machine `pio` may also be available from `~/.local/bin/pio` or
`~/.platformio/penv/bin/pio`.

## Build Firmware

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3
```

Equivalent when `pio` is on PATH:

```bash
pio run -d firmware -e m5stack_atoms3
```

The firmware build includes:

- `firmware/src/atom_main.cpp`
- `firmware/src/ble.cpp`
- M5Unified, ArduinoJson, and NimBLE-Arduino

There is also a smoke-test firmware environment:

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3_smoke
```

## Flash The AtomS3

Find the current serial port:

```bash
~/.platformio/penv/bin/pio device list
ls /dev/cu.usbmodem* /dev/ttyACM* /dev/ttyUSB* 2>/dev/null
```

Common macOS AtomS3 ports:

```text
/dev/cu.usbmodem101
/dev/cu.usbmodem1101
/dev/cu.usbmodemDC5475CBBC601
```

Flash with the helper:

```bash
./flash.sh /dev/cu.usbmodem1101 m5stack_atoms3
```

The helper changes into `firmware/` and runs:

```bash
pio run -e m5stack_atoms3 -t upload --upload-port <port>
```

After a successful flash the board may reset and re-enumerate under a different
`/dev/cu.usbmodem...` path. That is normal.

## Upload Mode

If flashing fails with:

```text
Failed to connect to ESP32-S3: No serial data received
```

put the AtomS3 into upload mode:

1. Hold the AtomS3 side button.
2. Keep holding until the internal green LED lights.
3. Release the button.
4. Re-run `pio device list` or `ls /dev/cu.usbmodem*`.
5. Flash again with the new port.

If the screen is dark after flashing, unplug and replug the AtomS3 without
holding the side button.

## Run The Daemon Manually

Print the payload without touching the device:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --print
```

Send one serial update:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial --once
```

Run continuously:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial
```

Pin a port when auto-detection picks the wrong device:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py \
  --transport serial \
  --serial-port /dev/cu.usbmodemDC5475CBBC601
```

Run over BLE instead of serial:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport ble
```

## Usage Configuration

The daemon loads optional environment values from:

```text
~/.config/codexmeter/env
```

Example:

```bash
CODEXMETER_TRANSPORT=serial
CODEXMETER_POLL_INTERVAL=60
CODEXMETER_ACTIVITY_POLL_INTERVAL=2
CODEXMETER_SERIAL_PORT=/dev/cu.usbmodemDC5475CBBC601
CODEXMETER_DAILY_BUDGET_USD=10
CODEXMETER_WEEKLY_BUDGET_USD=50
CODEXMETER_LOCAL_DAILY_SESSIONS=12
CODEXMETER_LOCAL_WEEKLY_SESSIONS=60
# OPENAI_ADMIN_KEY=sk-admin-...
```

For normal Codex usage display, the preferred source is the logged-in Codex auth
file:

```text
~/.codex/auth.json
```

An OpenAI admin/API key is optional and only used as the organization-cost
fallback. Do not commit real keys.

## Install As A Background Service

```bash
./install.sh
```

On macOS this writes:

```text
~/Library/LaunchAgents/com.justin.codexmeter.plist
~/.config/codexmeter/env
```

Logs:

```text
~/Library/Logs/codexmeter.log
~/Library/Logs/codexmeter.err.log
```

Restart on macOS:

```bash
launchctl unload ~/Library/LaunchAgents/com.justin.codexmeter.plist
launchctl load ~/Library/LaunchAgents/com.justin.codexmeter.plist
```

On Linux the installer writes a user systemd service:

```bash
systemctl --user status codex-usage-daemon
systemctl --user restart codex-usage-daemon
journalctl --user -u codex-usage-daemon -f
```

## Device UI

Short-press the AtomS3 button to cycle screens:

1. Usage: current window and weekly/secondary window remaining percentage.
2. Connection: BLE advertising/connected state, device name, and BLE MAC.
3. Status pet: animated pet plus rotating local status messages.
4. Pet selector: selected pet preview.
5. Now Working: current project, Codex task, current action, and last completed action.

Hold behavior:

- On the pet selector screen, hold to select the next pet.
- On the other screens, hold to clear BLE bonds.

Pet selection is persisted in ESP32 preferences under the `codexmeter`
namespace.

## Quick Health Checks

Build health:

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3
```

Daemon dependency health:

```bash
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python ./daemon/codex-usage-daemon.py --print
```

Serial send health:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial --once
```

Expected firmware boot serial output includes:

```text
{"ready":true,"target":"AtomS3"}
M5.begin done
BLE init done
AtomS3 dashboard ready
```

## Troubleshooting

### No Serial Port

Use a USB-C data cable, not a charge-only cable. Try a different physical port
and run `pio device list` again.

### Port Vanishes While Checking Serial

Opening USB CDC can reset ESP32-S3 sketches. The daemon waits five seconds
after opening serial before it sends a payload for this reason. If the port name
changes, rerun port discovery and use the new path.

### Daemon Shows Fallback Data

Check the logs for the source failure. The daemon tries:

1. Codex/ChatGPT OAuth usage from `~/.codex/auth.json`.
2. OpenAI organization costs from `OPENAI_ADMIN_KEY` or `OPENAI_API_KEY`.
3. Local Codex activity from `~/.codex/session_index.jsonl`.

Fallback payloads have `ok:false`, no live percentages, and a status like
`3d/12w sessions`.

### BLE Will Not Reconnect

Use the device hold action on Usage, Connection, or Status to clear BLE bonds.
The daemon also caches a BLE address at:

```text
~/.config/codexmeter/ble-address
```

Remove that file if the host keeps trying a stale address.

### JSON Parse Errors On Device

The firmware expects one compact JSON object per line. Keep the payload under
the 512-byte receive buffer used by serial and BLE. The daemon already compacts
text fields before sending.
