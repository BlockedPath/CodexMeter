# CodexMeter

A tiny AtomS3 desk display for Codex usage and connection status.

Forked from https://github.com/HermannBjorgvin/Clawdmeter.

CodexMeter runs on an **M5Stack AtomS3 ESP32-S3**. The firmware draws three button-cycled screens on the built-in display:

- usage remaining for the current and weekly Codex windows
- USB/BLE connection status
- a simple local status animation with rotating work-status text

The companion daemon runs on your computer and pushes compact JSON updates to the device over USB serial by default. BLE support still exists, but USB serial is the most reliable path while this is a small desk prototype.

![CodexMeter usage screen showing daily and weekly remaining usage](docs/images/codexmeter-usage.jpeg)

![CodexMeter status screen on the AtomS3 display](docs/images/codexmeter-status.jpeg)

## Hardware

- M5Stack AtomS3
- USB-C data cable
- macOS or Linux host

This README treats the AtomS3 as the supported target. Older inherited display experiments and bundled third-party art/font assets have been removed so the public repository stays lean.

## Quick Start

Install Python dependencies:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install platformio -r requirements.txt
```

Build the AtomS3 firmware:

```bash
.venv/bin/platformio run -d firmware -e m5stack_atoms3
```

Flash the device:

```bash
./flash.sh /dev/cu.usbmodem101 m5stack_atoms3
```

If macOS gives the board a different port, find it with:

```bash
~/.platformio/penv/bin/pio device list
```

AtomS3 upload ports commonly look like:

```text
/dev/cu.usbmodem101
/dev/cu.usbmodem1101
/dev/cu.usbmodemDC5475CBBC601
```

## Upload Mode

Sometimes the AtomS3 will show up in normal app mode and `esptool` will fail with:

```text
Failed to connect to ESP32-S3: No serial data received
```

Put it into upload mode:

1. Hold the AtomS3 side button.
2. Keep holding until the internal green LED lights.
3. Release the button.
4. Run `./flash.sh <port> m5stack_atoms3` again.

The port name may change after this gesture, so re-run `pio device list` if flashing says the port disappeared.

## Running The Daemon

Print the current payload without sending it:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --print
```

Send one USB serial update:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial --once
```

Run continuously:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial
```

Pin a specific serial port if auto-detection picks the wrong one:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py \
  --transport serial \
  --serial-port /dev/cu.usbmodemDC5475CBBC601
```

## Usage Sources

The daemon tries sources in this order:

1. **Codex/ChatGPT OAuth usage** from `~/.codex/auth.json`
2. **OpenAI organization costs** from `OPENAI_ADMIN_KEY` or `OPENAI_API_KEY`
3. **Local Codex activity fallback** from `~/.codex/session_index.jsonl`

For most Codex users, no API key is needed if the local Codex auth file is present. If you want OpenAI API org cost tracking as a fallback, create `~/.config/codexmeter/env`:

```bash
mkdir -p ~/.config/codexmeter
chmod 700 ~/.config/codexmeter
$EDITOR ~/.config/codexmeter/env
```

Example env file:

```bash
OPENAI_ADMIN_KEY=sk-admin-...
CODEXMETER_DAILY_BUDGET_USD=10
CODEXMETER_WEEKLY_BUDGET_USD=50
CODEXMETER_TRANSPORT=serial
CODEXMETER_POLL_INTERVAL=60
```

## Background Service

Install the daemon as a user service:

```bash
./install.sh
```

On macOS this creates a LaunchAgent and writes logs to:

```text
~/Library/Logs/codexmeter.log
~/Library/Logs/codexmeter.err.log
```

On Linux:

```bash
systemctl --user status codex-usage-daemon
journalctl --user -u codex-usage-daemon -f
```

## Device UI

Press the AtomS3 button to cycle screens:

1. **Usage** - current and weekly Codex remaining percentages plus reset timing
2. **Connection** - USB/BLE status and device identity
3. **Status** - simple built-in animation with rotating status phrases
4. **Pet Select** - preview the available pets and choose the one shown on the status screen

Hold the button on **Pet Select** to cycle pets. Hold the button on **Connection** to clear BLE bonds.

## Host Protocol

The host sends one compact JSON object per line over USB serial:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"120 credits","ok":true}
```

Fields:

| Field | Meaning |
| --- | --- |
| `s` | Current window remaining percentage |
| `sr` | Current window reset time in minutes |
| `w` | Weekly or secondary window remaining percentage |
| `wr` | Weekly or secondary reset time in minutes |
| `st` | Short status string |
| `ok` | Whether live usage data was available |

BLE uses the same payload on the RX characteristic.

| Item | UUID |
| --- | --- |
| Device name | `Codex Controller` |
| Data service | `434f4445-584d-4554-4552-000000000001` |
| RX characteristic | `434f4445-584d-4554-4552-000000000002` |
| TX characteristic | `434f4445-584d-4554-4552-000000000003` |
| Refresh characteristic | `434f4445-584d-4554-4552-000000000004` |

## Repository Map

```text
firmware/                    PlatformIO firmware
firmware/src/atom_main.cpp   AtomS3 app entrypoint
daemon/codex-usage-daemon.py Host daemon
install.sh                   LaunchAgent/systemd installer
flash.sh                     Build and upload helper
tools/                       Optional local asset conversion helpers
```

## Troubleshooting

### No serial port appears

Use a USB-C data cable, not a charge-only cable. Try a different port, then run:

```bash
~/.platformio/penv/bin/pio device list
```

### Port changed during flashing

The AtomS3 can re-enumerate while switching between app mode and upload mode. Re-run `pio device list` and retry with the new `/dev/cu.usbmodem...` path.

### Screen is dark after flashing

Unplug and replug the AtomS3 without holding the side button. If it stays in upload mode, tap reset or power-cycle it again.

### Daemon sends fallback data

Check `~/.codex/auth.json`. If you want API org-cost fallback, set `OPENAI_ADMIN_KEY` in `~/.config/codexmeter/env`.

## Credits And Asset Note

CodexMeter started as an adaptation of [HermannBjorgvin/Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter). Bundled demo images, generated brand-font files, third-party pixel animation data, and local pet art have been removed from this public tree.
