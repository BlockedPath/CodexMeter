# Architecture

How CodexMeter's components fit together and communicate.

## System Diagram

```text
┌─────────────────────────────────────────────────────────┐
│                     Data Sources                         │
│  ┌──────────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │ Codex OAuth API  │  │ OpenAI Costs │  │ Local     │  │
│  │ chatgpt.com/wham │  │ /v1/costs    │  │ ~/.codex  │  │
│  └────────┬─────────┘  └──────┬───────┘  └─────┬─────┘  │
│           │                   │                 │        │
│           └───────────────────┼─────────────────┘        │
│                               │                          │
└───────────────────────────────┼──────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────┐
│                 Python Daemon                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Usage Source │  │ Activity     │  │ Transports    │  │
│  │ 3-tier       │  │ Enrichment   │  │ serial / BLE  │  │
│  │ fallback     │  │ (project,    │  │ / HTTP        │  │
│  │              │  │  action...)  │  │               │  │
│  └──────────────┘  └──────────────┘  └───────┬───────┘  │
│                                              │           │
└──────────────────────────────────────────────┼───────────┘
                                               │
                    ┌──────────────┬───────────┼───────────┐
                    │              │           │           │
                    ▼              ▼           ▼           │
              ┌──────────┐  ┌──────────┐  ┌──────────┐    │
              │ USB      │  │ BLE GATT │  │ HTTP     │    │
              │ Serial   │  │ Service  │  │ :9595    │    │
              │ 115200   │  │ 0x0001   │  │ /usage   │    │
              └────┬─────┘  └────┬─────┘  └────┬─────┘    │
                   │             │             │           │
                   ▼             ▼             ▼           │
              ┌──────────────────────┐    ┌──────────┐    │
              │   AtomS3 Firmware    │    │ iOS App  │    │
              │   128×128 Display    │    │ & Widget │    │
              └──────────────────────┘    └──────────┘    │
```

## Data Flow

### 1. Usage Gathering

The daemon calls `usage_snapshot()` every 60 seconds (configurable via `CODEXMETER_POLL_INTERVAL`). Three sources in priority order:

| Priority | Source | Requires | Shows |
|---|---|---|---|
| 1 | Codex OAuth Usage API | `~/.codex/auth.json` | Rate-limit %, credit balance |
| 2 | OpenAI Org Costs API | `OPENAI_ADMIN_KEY` | Spending vs. daily/weekly budget |
| 3 | Local Session Counting | `~/.codex/session_index.jsonl` | Session counts, `ok: false` |

### 2. Activity Enrichment

`with_codex_activity()` reads the latest Codex session JSONL file under `~/.codex/sessions` and extracts:

- **Project** — derived from `cwd` in session metadata
- **Thread title** — from `session_index.jsonl` by session ID
- **Current action** — inferred from recent tool calls (e.g., "Editing files", "Searching files", "Building firmware")
- **Last completed** — from finalized assistant messages or task completion events

### 3. Payload Format

Compact JSON, one object per update. Serial adds `\n`; BLE writes raw bytes.

```json
{
  "s": 45,           // primary window remaining %
  "sr": 120,         // primary reset in minutes
  "w": 28,           // secondary/weekly remaining %
  "wr": 7200,        // secondary reset in minutes
  "st": "120 credits", // status string
  "ok": true,         // live data flag
  "pr": "CodexMeter", // project name
  "pt": "Update docs", // thread title
  "m": "Editing files", // current activity
  "lc": "Added TODO"   // last completed
}
```

### 4. Transport Layer

| Transport | Protocol | Use Case | Config |
|---|---|---|---|
| USB Serial | 115200 baud, newline-delimited JSON | Primary — AtomS3 connected via USB-C | `CODEXMETER_TRANSPORT=serial` |
| BLE | GATT write to RX characteristic | Wireless — AtomS3 in BLE range | `CODEXMETER_TRANSPORT=ble` |
| HTTP | REST API on `:9595` | iOS app, external consumers, mDNS discovery | Always on when daemon runs |

### 5. Firmware Rendering

The AtomS3 firmware (`atom_main.cpp`) runs a main loop:

1. Checks button state (click → next screen, hold → bond clear or pet select)
2. Polls serial for newline-delimited JSON
3. Parses payload into `UsageSnapshot` struct
4. Redraws current screen if data changed
5. Updates pet animation frame every ~200ms
6. Handles BLE events (connect, disconnect, write, subscribe)

Five screens rendered on a 128×128 RGB565 canvas:

| Index | Screen | Data Source |
|---|---|---|
| 0 | Usage | `s`, `sr`, `w`, `wr`, `st` |
| 1 | Connection | BLE state (internal) |
| 2 | Status Pet | `pt`, `m` + local animation |
| 3 | Pet Selector | NVRAM preference `pet_v2` |
| 4 | Now Working | `pr`, `pt`, `m`, `lc` |

### 6. iOS Discovery

```
Daemon (zeroconf)                     iOS App (NetServiceBrowser)
     │                                        │
     │  mDNS: codexmeter._http._tcp.local    │
     ├────────────────────────────────────────▶
     │                                        │  resolves to IP:9595
     │                                        │  polls GET /usage every 30s
     │◀────────────────────────────────────────┤
     │  HTTP 200: JSON payload                │
```

---

## BLE GATT Reference

| Item | UUID | Properties |
|---|---|---|
| Data Service | `434f4445-584d-4554-4552-000000000001` | — |
| RX Characteristic | `...0002` | Write, Write Without Response |
| TX Characteristic | `...0003` | Read, Notify |
| Refresh Request | `...0004` | Notify |

- **Device name:** `Codex Controller`
- **RX:** host writes usage payload bytes here
- **TX:** device sends `{"ack":true}` or `{"err":true}` after parsing
- **Refresh:** device notifies a single byte when it needs a fresh payload (triggered when host subscribes and no data received yet)

---

## Key Design Decisions

1. **Daemon is the single source of truth** — firmware and iOS app are pure consumers; they don't call APIs
2. **3-tier data fallback** — if Codex OAuth fails, try OpenAI costs; if that fails, count local sessions
3. **Compact payloads** — device buffer is 512 bytes; payloads stay well under with ASCII-safe text compaction
4. **USB serial is primary** — lower latency, no pairing, no battery concerns; BLE is secondary
5. **Asset warning** — current pet sprites are fan art inherited from upstream; replace before redistributing
