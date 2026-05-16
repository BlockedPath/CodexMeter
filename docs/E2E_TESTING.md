End-to-End Testing — CodexMeter

This doc explains how to validate the full end-to-end flow: daemon → HTTP/mDNS → iOS app → BLE/serial device.

Prerequisites

- Python 3.10+ and the project's .venv activated with required packages installed:
  .venv/bin/python -m pip install -r requirements.txt
- An ESP32 AtomS3 flashed with the firmware in `firmware/` and connected by USB or available via BLE.
- An iOS device (recommended) with the CodexMeterApp installed from Xcode (Local Network permission will be requested).

1) Start the daemon (HTTP + serial)

Run the daemon with HTTP enabled and serial transport (or `--transport none` to test HTTP only):

.venv/bin/python ./daemon/codex-usage-daemon.py --transport serial --http-port 9595

Expect:

- Console logs showing "HTTP server listening on 0.0.0.0:9595"
- If zeroconf is installed, a log line "Advertised mDNS service codexmeter at `ip:9595`"
- If serial transport finds the device, logs like "Sent over serial: { ... }"

1) Verify HTTP endpoints locally

From the same machine (or another on the same LAN) test the endpoints:

curl http://localhost:9595/usage
curl http://localhost:9595/status

Both should return JSON (usage and status objects). `Access-Control-Allow-Origin: *` is served so a browser can fetch from a different origin during development.

1) Verify mDNS advertisement

On macOS, run this in Terminal to look for the advertised service (if zeroconf is available and the daemon advertised):

dns-sd -B _http._tcp

Or use `dns-sd -L codexmeter _http._tcp local` to resolve the published service name.

1) Run the iOS app and observe discovery

- Build & run the iOS app from Xcode onto a device (not simulator) to allow Local Network permission. The system will prompt for Local Network access; accept it.
- Open Settings (gear) in the app. The "Discovered on Local Network" section should populate with discovered services (name + URL).
- Tap a discovered service to connect. The dashboard should update and the app will poll `/usage` every 30s.

1) Verify data reaches the AtomS3

If the daemon is configured to push over serial or BLE, the device screen should update shortly after each poll. The daemon prints logs about sending payloads (see daemon console or the LaunchAgent log file).

1) Troubleshooting tips

- If the iOS app does not see services, confirm the Mac and iOS device are on the same Wi‑Fi network (mDNS does not traverse subnets).
- Check that the daemon printed an mDNS advertisement line; if not, ensure `zeroconf` is installed in the daemon environment (`pip install zeroconf`) and rerun.
- Use `tcpdump -i <iface> port 5353` to inspect multicast DNS traffic when diagnosing discovery problems.

1) Run unit tests (local)

Run the project's unit tests using pytest:

.venv/bin/python -m pytest -q

This runs the Python unit tests in `tests/` and verifies discovery and parsing helpers where available.

If you want, I can add a small end-to-end checklist script (macOS) to automate steps 2–4.
