# CodexMeter System Reference

This file describes how CodexMeter works internally: firmware, host daemon,
data sources, transports, and payload format.

## High-Level Architecture

```text
Codex/ChatGPT usage API
OpenAI organization costs API
Local ~/.codex activity files
        |
        v
daemon/codex-usage-daemon.py
        |
        | USB serial newline JSON, or BLE GATT write
        v
M5Stack AtomS3 firmware
        |
        v
128x128 display: usage, connection, status pet, pet selector
```

The host daemon owns data gathering and transport. The AtomS3 firmware owns the
screen UI, BLE GATT server, USB serial parser, pet animation, and button input.

## Firmware Shape

PlatformIO environment:

```ini
[env:m5stack_atoms3]
platform = https://github.com/pioarduino/platform-espressif32/releases/download/55.03.38-1/platform-espressif32.zip
board = m5stack-atoms3
framework = arduino
upload_speed = 1500000
monitor_speed = 115200
```

Main firmware files:

- `firmware/src/atom_main.cpp`: app setup, display rendering, serial JSON
  parser, button behavior, pet state, payload parsing.
- `firmware/src/ble.cpp`: NimBLE server, custom service/characteristics,
  advertising, ack/nack notifications, refresh request notification, bond
  clearing.
- `firmware/src/data.h`: usage data structure consumed by the app.
- `firmware/src/*_sprite.h`: generated RGB565/alpha pet animation frames.
- `firmware/src/codex_icon.h`: Codex mark shown in the usage header.

The firmware boots serial at 115200, initializes M5Unified for AtomS3, creates a
128x128 canvas, loads the persisted pet choice, draws the first screen, starts
BLE, and then enters a loop that updates button state, BLE state, serial input,
and pet animation.

## Device State

The active runtime state is:

- `usage`: latest parsed usage payload.
- `screen`: current screen index, `0..4`.
- `active_pet`: selected pet style, persisted in ESP32 preferences as
  `pet_v2`.
- `last_ble_state`: last rendered BLE state for connection-screen refreshes.
- `serial_buf`: line buffer for newline-delimited JSON from USB serial.
- `pet_frame`, `pet_anim_state`, `pet_message_idx`: animation state.

The firmware does not call any external API. It only renders the newest payload
provided by the host.

## Screens

Screen order:

1. Usage: current/primary remaining percentage, reset time, weekly/secondary
   remaining percentage, and status text.
2. Bluetooth: BLE state, device name, and MAC address.
3. Status pet: animated pet with rotating local status text.
4. Pet selector: preview of the current pet and hold-to-select behavior.
5. Now Working: current project, Codex task/thread title, current action, and
   last completed action.

Button behavior:

- `wasClicked`: advances to the next screen.
- `wasHold` on screen 3: selects the next pet and persists it.
- `wasHold` on other screens: clears BLE bonds and redraws.

## Payload Format

The daemon sends one compact JSON object per update.

Serial transport appends a newline:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"120 credits","ok":true,"pr":"CodexMeter","pt":"Update docs","m":"Editing files","lc":"Added TODO"}
```

BLE transport writes the same JSON bytes to the RX characteristic.

Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `s` | number | Primary/current usage window remaining percentage. |
| `sr` | number | Primary/current reset time in minutes. `-1` means unknown. |
| `w` | number | Secondary/weekly usage window remaining percentage. |
| `wr` | number | Secondary/weekly reset time in minutes. `-1` means unknown. |
| `st` | string | Short status string such as `120 credits` or `$2.31 today`. |
| `ok` | boolean | `true` when live usage data is available. |
| `pr` | string | Optional current project/repo name. |
| `pt` | string | Optional pet title, usually the current Codex thread name. |
| `m` | string | Optional pet message, usually current Codex activity. |
| `lc` | string | Optional last completed action/message. |

The daemon uses compact JSON separators and ASCII-safe text compaction to keep
payloads small. The firmware receive buffers are 512 bytes.

## Firmware Payload Handling

Serial path:

1. `poll_serial_json()` reads `Serial` byte-by-byte.
2. `\r` is ignored.
3. `\n` terminates a payload.
4. `handle_payload()` parses the line.
5. A valid payload updates `usage`, sends BLE ack if connected, and redraws
   Usage or Status Pet if visible.

BLE path:

1. Host writes payload bytes to RX characteristic.
2. `RxCallbacks::onWrite` copies bytes into `rx_buf`.
3. Main loop sees `ble_has_data()`.
4. `handle_payload(ble_get_data())` parses and redraws as needed.

On parse success, the device notifies TX with:

```json
{"ack":true}
```

On parse failure:

```json
{"err":true}
```

## BLE Reference

Device name:

```text
Codex Controller
```

GATT layout:

| Item | UUID | Properties |
| --- | --- | --- |
| Data service | `434f4445-584d-4554-4552-000000000001` | service |
| RX | `434f4445-584d-4554-4552-000000000002` | write, write without response |
| TX | `434f4445-584d-4554-4552-000000000003` | read, notify |
| Refresh request | `434f4445-584d-4554-4552-000000000004` | notify |

When the host subscribes to the refresh characteristic and the device has not
received data yet, the firmware notifies a single byte to request a fresh
payload. This avoids a newly connected BLE display sitting empty until the next
normal daemon poll.

## Host Daemon Data Sources

`usage_snapshot()` tries sources in order:

1. `codex_oauth_usage_snapshot()`
2. `openai_usage_snapshot()`
3. `local_codex_activity_snapshot()`

### Codex OAuth Usage

Reads:

```text
~/.codex/auth.json
```

Uses the access token against:

```text
https://chatgpt.com/backend-api/wham/usage
```

If an account id is available, the daemon sends it as `ChatGPT-Account-Id`.

The daemon reads `rate_limit.primary_window`,
`rate_limit.secondary_window`, and `credits.balance`. Percentages are converted
from `used_percent` into remaining percentages. Reset times come from
`reset_after_seconds` or `reset_at`.

### OpenAI Organization Costs

Reads one of:

```text
OPENAI_ADMIN_KEY
OPENAI_API_KEY
```

Calls:

```text
https://api.openai.com/v1/organization/costs
```

The daily and weekly cost totals are divided by configured budgets:

```text
CODEXMETER_DAILY_BUDGET_USD
CODEXMETER_WEEKLY_BUDGET_USD
```

This fallback reports spending progress rather than Codex rate-limit windows.

### Local Codex Activity Fallback

Reads:

```text
~/.codex/session_index.jsonl
```

It counts sessions updated since local midnight and since the start of the local
week. This produces a heartbeat status even when live usage APIs are
unavailable. The payload has `ok:false`, so the firmware renders fallback labels
instead of live percentages.

## Current Activity Overlay

Every live or fallback usage snapshot is enriched by `with_codex_activity()`.
That function reads the latest Codex session JSONL under:

```text
~/.codex/sessions
```

It extracts:

- `pr`: project/repo name from the current Codex session `cwd`.
- `pt`: thread title from `session_index.jsonl`.
- `m`: activity inferred from the newest session event.
- `lc`: last completed assistant action or task summary.

Examples of inferred activity:

- `Searching files` for `rg`, `grep`, `find`, or `mdfind`.
- `Reading file` for `sed`, `tail`, `head`, `cat`, `nl`, or `less`.
- `Building firmware` for `platformio` or `pio`.
- `Checking git` for Git commands.
- `Editing files` for `apply_patch`.
- `Thinking` while a tool result or assistant message is in progress.
- Final assistant text when a task completes.

The firmware shows this on the Now Working screen. Generic pet animation text
continues to rotate on the Status Pet screen.

## Host Transports

### Serial

Default transport:

```text
CODEXMETER_TRANSPORT=serial
```

Auto-detection checks these patterns in order:

```text
/dev/cu.usbmodemDC5475CBBC601
/dev/cu.usbmodem*
/dev/ttyACM*
/dev/ttyUSB*
```

Serial is opened at 115200 baud with DTR/RTS disabled. The daemon sleeps for
five seconds after opening because USB CDC can reset ESP32-S3 sketches.

Continuous serial loop:

1. Open port.
2. Wait five seconds.
3. Fetch usage snapshot.
4. Send a payload whenever the compact payload changes.
5. Refresh usage every `CODEXMETER_POLL_INTERVAL`.
6. Recompute local activity every `CODEXMETER_ACTIVITY_POLL_INTERVAL`.

### BLE

BLE scans for device name `Codex Controller` unless a cached address exists at:

```text
~/.config/codexmeter/ble-address
```

The daemon subscribes to refresh notifications, writes payloads to RX, and
retries with exponential backoff after disconnects. If a BLE error occurs, it
deletes the cached address so the next loop scans again.

## Background Service Model

`install.sh` picks Python in this order:

1. Repo `.venv/bin/python`
2. `~/.platformio/penv/bin/python`
3. `python3` on PATH

It installs `requirements.txt`, creates `~/.config/codexmeter/env` if missing,
then installs an OS-specific user service.

macOS:

- LaunchAgent label: `com.justin.codexmeter`
- Plist: `~/Library/LaunchAgents/com.justin.codexmeter.plist`
- stdout: `~/Library/Logs/codexmeter.log`
- stderr: `~/Library/Logs/codexmeter.err.log`

Linux:

- User service: `codex-usage-daemon`
- Template: `daemon/codex-usage-daemon.service`
- Installed into: `~/.config/systemd/user/codex-usage-daemon.service`

## Important Constraints

- Keep payloads compact; the device buffer is 512 bytes.
- Prefer USB serial for normal operation.
- BLE address caching can become stale after device resets or firmware changes.
- Opening serial can reset the AtomS3; allow time before sending.
- The firmware is currently AtomS3-specific and assumes a 128x128 display.
- `OPENAI_ADMIN_KEY` and `OPENAI_API_KEY` are secrets and must stay outside git.
- Pet sprite headers are generated assets; update source images and regenerate
  rather than hand-editing frame arrays.
