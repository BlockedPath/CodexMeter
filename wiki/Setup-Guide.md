# Setup Guide

Complete walkthrough for getting CodexMeter running on your desk.

## Prerequisites

### Hardware
- [M5Stack AtomS3](https://shop.m5stack.com/products/atom-s3) (~$15)
- USB-C **data** cable (not charge-only)

### Software
- Python 3.10+ (`python3 --version`)
- git
- macOS or Linux (Windows untested)
- [Codex](https://github.com/openai/codex) installed with an active session

### Optional
- Xcode 16.0+ and XcodeGen for the iOS app
- `OPENAI_ADMIN_KEY` for OpenAI cost tracking fallback

---

## Step 1: Clone and Install Dependencies

```bash
git clone https://github.com/BlockedPath/CodexMeter.git
cd CodexMeter
python3 -m venv .venv
.venv/bin/pip install platformio -r requirements.txt
```

## Step 2: Health Check

```bash
bash doctor.sh
```

This checks Python, virtual env, deps, PlatformIO, AtomS3 connection, Codex auth, and API keys. Fix any failures before continuing.

## Step 3: Smoke Test Your Hardware

Connect the AtomS3 via USB-C, then:

```bash
.venv/bin/platformio device list
# Find VID:PID=303A:1001 → e.g. /dev/cu.usbmodem101

.venv/bin/platformio run -d firmware -e m5stack_atoms3_smoke -t upload --upload-port /dev/cu.usbmodem101
```

The screen should cycle red → green → blue, then show "AtomS3 CodexMeter" in white.

## Step 4: Flash Firmware

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3 -t upload --upload-port /dev/cu.usbmodem101
```

Or use the helper:

```bash
bash flash.sh /dev/cu.usbmodem101 m5stack_atoms3
```

The screen shows "waiting for host" on a dark background when ready.

> **Note:** The port name may change after flashing (device re-enumerates). Run `platformio device list` again.

## Step 5: Run the Daemon

```bash
# Test with a single update
.venv/bin/python daemon/codex-usage-daemon.py --transport serial --once

# Run continuously (refreshes every 60s)
.venv/bin/python daemon/codex-usage-daemon.py --transport serial
```

The AtomS3 display should update from "waiting for host" to live usage data.

## Step 6 (Optional): Background Service

```bash
bash install.sh
```

| OS | Mechanism | Logs |
|---|---|---|
| macOS | LaunchAgent | `~/Library/Logs/codexmeter.log` |
| Linux | systemd user | `journalctl --user -u codex-usage-daemon` |

## Step 7 (Optional): iOS App

```bash
cd ios/CodexMeterApp
brew install xcodegen        # if not installed
xcodegen generate
open CodexMeterApp.xcodeproj
```

Select your iOS 17+ device as target, build and run (⌘R). The app discovers the daemon via Bonjour — ensure your Mac and iPhone are on the same Wi‑Fi network.

### iOS-Only (No AtomS3)

Run the daemon HTTP-only:

```bash
.venv/bin/python daemon/codex-usage-daemon.py --transport none --http-port 9595
```

The iOS app will still discover and display usage data without a physical device.

---

## What's Next?

- Press the AtomS3 button to cycle through screens
- Hold the button on the Pet Selector screen to change your pet
- Hold on any other screen to clear BLE bonds
- Check [Troubleshooting](Troubleshooting) if anything goes wrong
