# Daemon API Reference

HTTP API and payload format reference for the CodexMeter daemon.

---

## HTTP Endpoints

The daemon serves on `http://0.0.0.0:9595` by default (configurable via `--http-port` or `CODEXMETER_HTTP_PORT`).

### GET /usage

Returns the current usage payload as compact JSON.

**Headers:**
- `Content-Type: application/json`
- `Access-Control-Allow-Origin: *`
- `Cache-Control: no-cache`

**Response:**
```json
{
  "s": 45,
  "sr": 120,
  "w": 28,
  "wr": 7200,
  "st": "120 credits",
  "ok": true,
  "pr": "CodexMeter",
  "pt": "Update docs",
  "m": "Editing files",
  "lc": "Added TODO"
}
```

### GET /status

Returns daemon health and metadata.

**Response:**
```json
{
  "ok": true,
  "source": "codex_oauth",
  "last_success_at": "2025-05-17T16:30:00Z",
  "last_error_at": null,
  "last_error": "",
  "payload_updated_at": "2025-05-17T16:30:00Z",
  "payload_age_seconds": 12,
  "uptime_seconds": 3600
}
```

---

## Payload Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `s` | int | yes | Primary/current usage window remaining percentage (0–100) |
| `sr` | int | yes | Primary window reset in minutes (-1 = unknown) |
| `w` | int | yes | Secondary/weekly usage window remaining percentage (0–100) |
| `wr` | int | yes | Secondary window reset in minutes (-1 = unknown) |
| `st` | string | yes | Short status string, max 24 chars (e.g., `120 credits`, `$2.31 today`) |
| `ok` | bool | yes | `true` when live API data is available; `false` for local fallback |
| `pr` | string | no | Project/repo name, max 20 chars |
| `pt` | string | no | Thread title / pet label, max 26 chars |
| `m` | string | no | Current activity description, max 42 chars |
| `lc` | string | no | Last completed action, max 42 chars |

**Examples:**

Healthy usage from Codex OAuth:
```json
{"s":87,"sr":240,"w":72,"wr":7200,"st":"120 credits","ok":true}
```

Cost tracking from OpenAI API:
```json
{"s":92,"sr":180,"w":84,"wr":4200,"st":"$0.84 today","ok":true}
```

Local fallback (no API access):
```json
{"s":0,"sr":120,"w":0,"wr":7200,"st":"3d/17w sessions","ok":false}
```

With activity enrichment:
```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"120 credits","ok":true,"pr":"CodexMeter","pt":"Add BLE docs","m":"Editing files","lc":"Added FAQ section"}
```

---

## BLE GATT Reference

**Device name:** `Codex Controller`

**Service:** `434f4445-584d-4554-4552-000000000001`

| Characteristic | UUID | Properties | Direction | Description |
|---|---|---|---|---|
| RX | `...0002` | Write, Write Without Response | Host → Device | Host writes usage payload bytes here |
| TX | `...0003` | Read, Notify | Device → Host | Device sends `{"ack":true}` or `{"err":true}` |
| Refresh Request | `...0004` | Notify | Device → Host | Device notifies a byte when data is needed |

**Flow:**
1. Host connects and subscribes to Refresh Request (`...0004`)
2. Device notifies a byte → host gathers usage and writes to RX (`...0002`)
3. Device parses JSON, sends ack/nack on TX (`...0003`)
4. Host periodically refreshes (every `CODEXMETER_POLL_INTERVAL` seconds)

---

## mDNS / Bonjour Advertisement

When `zeroconf` is installed, the daemon advertises:

| Field | Value |
|---|---|
| Service Type | `_http._tcp` |
| Service Name | `codexmeter._http._tcp.local` |
| Port | `9595` (configurable) |
| TXT Record | `path=/usage` |

The iOS app uses `NetServiceBrowser` to discover `_http._tcp` services and resolves the IPv4 address to construct the base URL.

---

## Canned Test Payloads

For UI validation without a live Codex session:

```bash
# Healthy usage
.venv/bin/python daemon/codex-usage-daemon.py --test-payload happy --transport serial --once

# Critically low
.venv/bin/python daemon/codex-usage-daemon.py --test-payload low --transport serial --once

# Local fallback mode
.venv/bin/python daemon/codex-usage-daemon.py --test-payload fallback --transport serial --once
```

| Preset | `s` | `w` | `st` | `ok` |
|---|---|---|---|---|
| `happy` | 87 | 72 | `$0.84 today` | true |
| `low` | 8 | 5 | `$9.61 today` | true |
| `fallback` | 0 | 0 | `needs login` | false |

---

## Environment Variables

All configurable via environment or `~/.config/codexmeter/env`:

| Variable | Default | Description |
|---|---|---|
| `CODEXMETER_TRANSPORT` | `serial` | Transport: `serial`, `ble`, or `none` |
| `CODEXMETER_SERIAL_PORT` | auto | Explicit serial port path |
| `CODEXMETER_POLL_INTERVAL` | `60` | Seconds between usage refreshes |
| `CODEXMETER_ACTIVITY_POLL_INTERVAL` | `2` | Activity re-check interval (seconds) |
| `CODEXMETER_SCAN_TIMEOUT` | `10` | BLE scan timeout (seconds) |
| `CODEXMETER_HTTP_PORT` | `9595` | HTTP server port |
| `CODEXMETER_DAILY_BUDGET_USD` | `10` | Daily budget for cost tracking |
| `CODEXMETER_WEEKLY_BUDGET_USD` | `50` | Weekly budget for cost tracking |
| `CODEXMETER_DEVICE_NAME` | `Codex Controller` | BLE device name filter |
| `CODEXMETER_BLE_TRUST_FIRST` | `false` | Accept first BLE match |
| `OPENAI_ADMIN_KEY` | — | OpenAI admin key for cost API |
| `OPENAI_API_KEY` | — | Alternative: standard API key |
| `CODEX_HOME` | `~/.codex` | Codex config directory override |
