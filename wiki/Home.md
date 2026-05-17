# Welcome to the CodexMeter Wiki

CodexMeter is a tiny ESP32-S3 desk display for [Codex](https://github.com/openai/codex) usage monitoring, paired with a cross-platform host daemon and an iOS companion app.

---

## What Is CodexMeter?

CodexMeter shows your current Codex rate-limit windows, connection status, an animated status pet, and your active Codex session — all on a 128×128 screen the size of a postage stamp. A Python daemon runs on your Mac or Linux machine, gathers usage data from Codex/OpenAI, and sends it to the display over USB serial or BLE. An iOS app lets you check your usage from your iPhone.

| Component | Language | Purpose |
|---|---|---|
| **Firmware** | C++ (Arduino / ESP32-S3) | Renders usage data on the M5Stack AtomS3 display |
| **Daemon** | Python 3.10+ | Gathers Codex/OpenAI usage, pushes to device over serial/BLE, serves HTTP API |
| **iOS App** | Swift (iOS 17+) | Discovers daemon via Bonjour, shows usage dashboard and widget |

---

## Quick Navigation

### For Everyone

| Page | Description |
|---|---|
| [Home](Home) | You're here — project overview |
| [Setup Guide](Setup-Guide) | Full installation walkthrough |
| [Architecture](Architecture) | How the pieces fit together |
| [Troubleshooting](Troubleshooting) | Common problems and solutions |

### For Developers

| Page | Description |
|---|---|
| [Daemon API Reference](API-Reference) | HTTP endpoints, payload format, BLE GATT reference |
| [Firmware Development](Firmware-Development) | Building, flashing, pet sprite format |
| [iOS App Development](iOS-App-Development) | XcodeGen, Bonjour discovery, widget structure |
| [Contributing](Contributing) | How to contribute, style guide, PR process |

---

## How It Works (30-Second Version)

```text
Codex OAuth API ─┐
OpenAI Costs API ─┼──→ Python Daemon ──┬── USB Serial ──→ AtomS3 Display
Local Activity   ─┘                     ├── BLE ────────→ AtomS3 Display
                                        └── HTTP :9595 ──→ iOS App / Widget
```

1. The **daemon** runs on your Mac/Linux, polls Codex usage every 60 seconds
2. It enriches the data with your current Codex session activity (project, task, action)
3. It pushes a compact JSON payload to the **AtomS3** over USB serial (or BLE)
4. The **firmware** renders five screens: Usage, Connection, Status Pet, Pet Selector, Now Working
5. Simultaneously, the daemon serves an HTTP API on port 9595
6. The **iOS app** discovers the daemon via Bonjour/mDNS and polls `/usage` every 30s

---

## Screens

Press the AtomS3 button to cycle through screens:

| Screen | Shows |
|---|---|
| **Usage** | Primary (daily) and secondary (weekly) remaining percentages, reset countdowns, status |
| **Connection** | BLE state, device name, MAC address |
| **Status Pet** | Animated pet character with rotating status phrases |
| **Pet Selector** | Preview and select from Sukuna, Boba, Gojo, Itachi, ApuPepe, and more |
| **Now Working** | Active Codex session: project, thread, current action, last completed |

---

## Status

- **Firmware:** stable — builds and flashes on M5Stack AtomS3
- **Daemon:** stable — serial, BLE, HTTP transports all working; 3-tier data fallback
- **iOS App:** functional — Bonjour discovery, usage dashboard, widget extension
- **CI:** green — Python (ruff + pytest) and iOS (xcodebuild test) on every push

See the [project board](https://github.com/BlockedPath/CodexMeter/projects) for active work and the [TODO](../blob/main/TODO.md) for planned improvements.

---

## More Resources

- [Main README](../blob/main/README.md) — Full setup guide with prerequisites
- [System Reference](../blob/main/systm.md) — Protocol spec, data flow, constraints
- [End-to-End Testing](../blob/main/docs/E2E_TESTING.md) — Validation guide
- [Issue Tracker](https://github.com/BlockedPath/CodexMeter/issues)
