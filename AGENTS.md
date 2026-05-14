# CodexMeter Notes

CodexMeter is an ESP32-S3 desk display adapted from Clawdmeter for Codex/OpenAI usage.

## Project Shape

- `firmware/`: PlatformIO firmware for M5 Stack ESP32-S3.
- `daemon/codex-usage-daemon.py`: cross-platform BLE host daemon using `bleak`.
- `install.sh`: installs the daemon as a macOS LaunchAgent or Linux systemd user service.

## Development

Firmware build:

```bash
cd firmware
pio run
```

Daemon smoke test:

```bash
python3 -m pip install -r requirements.txt
./daemon/codex-usage-daemon.py --print
```

The daemon uses `OPENAI_ADMIN_KEY` or `OPENAI_API_KEY` against `https://api.openai.com/v1/organization/costs`. Without a usable key, it falls back to counting updated Codex sessions in `~/.codex/session_index.jsonl`.

## BLE

Device name: `Codex Controller`

Data service UUID: `434f4445-584d-4554-4552-000000000001`

The host writes compact JSON to RX:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"$2.31 today","ok":true}
```

## Asset Warning

The current tree still includes inherited upstream demo images, generated font C files, and pixel animation data. Replace those before treating this as a clean redistributable project.
