# CodexMeter

An ESP32 desk display for keeping an eye on Codex/OpenAI usage.

This project is adapted from [HermannBjorgvin/codexmeter](https://github.com/HermannBjorgvin/codexmeter). The current firmware targets an M5Stack AtomS3 ESP32-S3 with its built-in 0.85-inch display, and the host daemon defaults to USB serial updates for reliability.

## What it shows

- **Current**: today's OpenAI API cost as a percentage of `CODEXMETER_DAILY_BUDGET_USD`
- **Weekly**: this week's OpenAI API cost as a percentage of `CODEXMETER_WEEKLY_BUDGET_USD`
- **Fallback mode**: if no OpenAI admin/API key is available, it counts local Codex sessions updated in `~/.codex/session_index.jsonl`

OpenAI does not expose the same codex-style 5-hour/7-day Codex subscription utilization headers that Clawdmeter uses. CodexMeter therefore uses the official OpenAI organization costs endpoint for real spend tracking, and treats the configured budgets as the meter ceiling.

## Hardware

- [M5Stack AtomS3](https://docs.m5stack.com/en/core/AtomS3)
- USB-C data cable for flashing and host updates

## Host setup

```bash
python3 -m venv .venv
.venv/bin/python -m pip install platformio -r requirements.txt
export OPENAI_ADMIN_KEY="sk-admin-..."
export CODEXMETER_DAILY_BUDGET_USD=10
export CODEXMETER_WEEKLY_BUDGET_USD=50
.venv/bin/python ./daemon/codex-usage-daemon.py --print
```

For background service installs, put the same settings in `~/.config/codexmeter/env`:

```bash
mkdir -p ~/.config/codexmeter
chmod 700 ~/.config/codexmeter
$EDITOR ~/.config/codexmeter/env
```

Run it continuously over USB serial:

```bash
.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial
```

Install it as a background service:

```bash
./install.sh
```

On macOS, logs go to `~/Library/Logs/codexmeter.log`. On Linux, use:

```bash
systemctl --user status codex-usage-daemon
journalctl --user -u codex-usage-daemon -f
```

## Flash firmware

```bash
./flash.sh /dev/cu.usbmodem101
```

If auto-upload cannot enter the ESP32-S3 bootloader, hold the AtomS3 reset/side button until the internal green LED lights, release it, then rerun the flash command. In download mode the port is usually `/dev/cu.usbmodem101`.

After flashing, the daemon sends newline-delimited compact JSON over USB serial. BLE support is still present in firmware, but USB serial is the default transport.

## Host Protocol

USB serial payloads are one compact JSON object per line:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"$2.31 today","ok":true}
```

The firmware also exposes a custom BLE GATT service for future wireless use.

| Item | UUID |
| --- | --- |
| Data Service | `434f4445-584d-4554-4552-000000000001` |
| RX Characteristic | `434f4445-584d-4554-4552-000000000002` |
| TX Characteristic | `434f4445-584d-4554-4552-000000000003` |
| Refresh Characteristic | `434f4445-584d-4554-4552-000000000004` |

Payload written to BLE RX:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"$2.31 today","ok":true}
```

Fields: `s` = current %, `sr` = current reset minutes, `w` = weekly %, `wr` = weekly reset minutes, `st` = short status, `ok` = success flag.

## Button

Press the AtomS3 front button to cycle between the usage screen and the transport/status screen. Hold it to clear BLE bonds.

## Credits and Assets

This started as a Codex adaptation of Clawdmeter. The inherited demo images, pixel-art animation data, and brand-font generated files come from the upstream project and may carry third-party licensing restrictions. Treat this as a working prototype until those assets are replaced with clean CodexMeter-owned art/fonts.
