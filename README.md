# CodexMeter

A tiny desk display for Codex usage on the M5Stack AtomS3.

CodexMeter shows your current Codex rate-limit windows, connection status, a
rotating status pet, and your active Codex session on a 128×128 screen the
size of a postage stamp. It sits next to your keyboard and updates live while
you work.

![CodexMeter usage screen showing daily and weekly remaining usage](docs/images/codexmeter-usage.jpeg)

![CodexMeter status screen on the AtomS3 display](docs/images/codexmeter-status.jpeg)

---

## What You Need

**Hardware:**

- [M5Stack AtomS3](https://shop.m5stack.com/products/atom-s3) (~$15) — the
  ESP32-S3 board with built-in 128×128 display
- USB-C **data** cable (not charge-only — must support data transfer)

**Software:**

- Python 3.10 or later (`python3 --version`)
- git
- macOS or Linux (Windows may work over serial but is untested)
- A [Codex](https://github.com/openai/codex) installation with an active
  session (the daemon reads `~/.codex/auth.json` for usage data)

---

## Setup — Step by Step

### 1. Clone and enter the project

```bash
git clone https://github.com/BlockedPath/CodexMeter.git
cd CodexMeter
```

### 2. Create a Python virtual environment

```bash
python3 -m venv .venv
.venv/bin/python -m pip install platformio -r requirements.txt
```

This installs PlatformIO (the ESP32 build system) plus the daemon's Python
dependencies (`bleak`, `pyserial`, `certifi`).

### 3. Verify your AtomS3 works (optional but recommended)

Flash the smoke-test firmware first to confirm your hardware and cable are
good:

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3_smoke -t upload
```

The screen should cycle red → green → blue, then show "AtomS3 CodexMeter" in
white. If this fails, see [admin.md](admin.md#troubleshooting).

### 4. Flash the CodexMeter firmware

First find your device port:

```bash
.venv/bin/platformio device list
```

Look for a line with `USB VID:PID=303A:1001` — the port will be something
like `/dev/cu.usbmodem101` or `/dev/cu.usbmodemDC5475CBBC601`.

Then flash:

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3 -t upload --upload-port /dev/cu.usbmodem101
```

Or use the helper script:

```bash
./flash.sh /dev/cu.usbmodem101 m5stack_atoms3
```

After flashing, the screen shows "waiting for host" on a dark background.
**Note:** the port name may change after flashing (the device re-enumerates).
Re-run `platformio device list` if you need the new port for the daemon.

### 5. Run the daemon

Print a sample payload to verify everything is working:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --print
```

You should see JSON with usage percentages and your current Codex session
info. If you see `"ok":false`, the daemon is using the local fallback — this
is normal if you're not running Codex right now.

Send one update to the device:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial --once
```

The AtomS3 screen should update from "waiting for host" to live usage data.

Run continuously (refreshes every 60 seconds):

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial
```

If auto-detection picks the wrong port, specify it:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py \
  --transport serial \
  --serial-port /dev/cu.usbmodemDC5475CBBC601
```

### 6. (Optional) Install as a background service

```bash
./install.sh
```

The daemon starts automatically on login and keeps the display updated. See
[admin.md](admin.md) for service lifecycle commands and log locations.

---

## What You'll See

Press the AtomS3 button to cycle through five screens:

| Screen | Shows |
| --- | --- |
| **Usage** | Current and weekly usage-remaining percentages, reset countdowns |
| **Connection** | Bluetooth state, device name, MAC address |
| **Status Pet** | Animated pet with rotating status phrases |
| **Pet Selector** | Preview and selection — hold to switch between Sukuna/Boba/Gojo/Itachi |
| **Now Working** | Active Codex session: project, task title, current action, last completed |

Hold the button on any non-selector screen to clear BLE bonds.

If the display shows percentages like `45%` / `28%` with a status like
`120 credits`, the daemon is reading live Codex usage data. If it shows
`--` with "needs login", the daemon fell back to local activity counting
— usually because Codex isn't running or `~/.codex/auth.json` is missing.

---

## How It Works

The daemon reads your Codex usage from `~/.codex/auth.json` (or OpenAI API
costs as a fallback). It sends a compact JSON payload to the AtomS3 over USB
serial. The firmware renders it on the display. See [systm.md](systm.md) for
the full protocol reference including payload fields, BLE UUIDs, and data
sources.

---

## Repository Map

```text
firmware/src/atom_main.cpp   App entrypoint and display rendering
firmware/src/ble.cpp         NimBLE GATT server
firmware/src/color_utils.h   RGB565 color utilities
firmware/src/text_utils.h    Text formatting utilities
firmware/src/*_sprite.h      Pet animation frame data (generated)
daemon/codex-usage-daemon.py Host daemon (serial/BLE/HTTP)
install.sh                   LaunchAgent/systemd installer
flash.sh                     Build and upload helper
tools/pet_to_lvgl.py         Pet sprite atlas converter
docs/                        Screenshots and documentation
```

---

## Troubleshooting & Advanced

See [admin.md](admin.md) for:

- Upload mode instructions
- Environment variables and usage config
- Health check commands
- BLE reconnection fixes
- Serial port debugging

See [systm.md](systm.md) for:

- Architecture and data flow
- Payload format specification
- BLE GATT reference
- Data source priority and fallback behavior

---

## Credits

Adapted from [HermannBjorgvin/Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter).
