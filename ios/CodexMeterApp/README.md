# CodexMeter iOS Companion

iPhone app that acts as the BLE host for your ESP32 CodexMeter display.
Logs into your ChatGPT/Codex account via OAuth, fetches real-time usage
data, and streams it to the ESP32 over Bluetooth Low Energy.

## How It Works

```
┌──────────┐     OAuth PKCE      ┌──────────────┐
│  OpenAI  │ ◄────────────────── │              │
│  Auth    │                     │  CodexMeter  │
└──────────┘                     │  iOS App     │
                                 │              │
┌──────────┐   usage JSON        │              │
│  Codex   │ ◄────────────────── │              │
│  API     │                     └──────┬───────┘
└──────────┘                            │
                                        │ BLE (compact JSON)
                                        │
                                 ┌──────▼───────┐
                                 │  ESP32-S3    │
                                 │  "Codex      │
                                 │  Controller" │
                                 └──────────────┘
```

- **OAuth PKCE**: Signs into your ChatGPT account using `ASWebAuthenticationSession`
  (no API key needed, tokens stored in iOS Keychain)
- **Usage API**: Polls `chatgpt.com/backend-api/wham/usage` every 60s
- **BLE**: Connects to the ESP32 as a CoreBluetooth central, writes JSON to
  the RX characteristic every 2s when data changes
- **UI**: Shows session/weekly usage bars, credit balance, BLE status

## Build & Install

### Prerequisites

- Mac with Xcode 16+
- Apple ID (free) or Apple Developer account ($99/yr)
- iOS 17.0+ device (iPhone)

### Option A: XcodeGen (recommended)

```bash
cd ios/CodexMeterApp

# Install xcodegen if needed
brew install xcodegen

# Generate the project
xcodegen generate

# Open in Xcode
open CodexMeterApp.xcodeproj
```

Then:
1. Select your team in Signing & Capabilities
2. Change the bundle identifier if needed
3. Build to your iPhone (Cmd+R)

### Option B: Manual Xcode Project

1. Open Xcode → New Project → iOS → App
2. Name: `CodexMeterApp`, Interface: SwiftUI
3. Delete the generated files
4. Drag all `.swift` files from `CodexMeterApp/` into the project
5. Replace Info.plist with the one provided (has BLE permissions)
6. Select your team in Signing & Capabilities
7. Build to your iPhone

### Option C: Free Sideloading (no paid developer account)

Without a paid account, iOS apps expire after 7 days. You can use:

- [AltStore](https://altstore.io) — installs on-device, auto-refreshes
- [SideStore](https://sidestore.io) — similar, no computer needed after setup

Build an `.ipa` from Xcode, then sideload with either tool.

## Required Permissions

The app needs:

| Permission | Why |
|---|---|
| Bluetooth | Discover and communicate with the ESP32 |
| Background BLE | Keep connection alive when app is backgrounded |

These are configured in `Info.plist`. No other permissions or network access
beyond talking to OpenAI's servers.

## Token Storage

OAuth tokens are stored in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock`.
Tokens are never sent anywhere except directly to `api.openai.com` and
`chatgpt.com`. No third-party servers involved.

## ESP32 Compatibility

No firmware changes needed. The app sends the same compact JSON format:

```json
{"s":45,"sr":120,"w":28,"wr":7200,"st":"507 credits","ok":true}
```

Activity fields (`pt`, `m`, `pr`, `lc`) are omitted since session data
isn't accessible from iPhone — the ESP32 uses its built-in defaults for
pet messages and titles.
