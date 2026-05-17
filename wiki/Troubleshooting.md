# Troubleshooting

Common issues and their solutions.

---

## Device Not Detected

```bash
.venv/bin/platformio device list
# Expected: VID:PID=303A:1001 (M5Stack AtomS3)
```

**Causes:**
- Using a charge-only USB-C cable — must be a **data** cable
- Device not in download mode — hold the AtomS3 button while plugging in
- macOS security blocking the serial driver — check System Settings → Privacy

## Port Changes After Flashing

The AtomS3 re-enumerates USB after a firmware upload, changing its device path.

**Fix:** Run `platformio device list` again to find the new port, then update your daemon command or `CODEXMETER_SERIAL_PORT`.

## Screen Shows "waiting for host"

Firmware is running but no payload received yet.

**Fix:**
```bash
.venv/bin/python daemon/codex-usage-daemon.py --transport serial --once
```

## Screen Shows "--" / "needs login"

Daemon fell back to local activity counting. Live API data unavailable.

**Causes:**
- Codex not running locally → start a Codex session
- `~/.codex/auth.json` missing or expired → log into Codex again
- No `OPENAI_ADMIN_KEY` set → optional: add to `~/.config/codexmeter/env`

## BLE Won't Connect

```bash
# Clear cached BLE address
rm ~/.config/codexmeter/ble-address

# Clear device bonds (hold button on any non-selector screen)
```

If multiple `Codex Controller` devices are visible:
```bash
CODEXMETER_BLE_TRUST_FIRST=1 .venv/bin/python daemon/codex-usage-daemon.py --transport ble
```

## iOS App Doesn't Discover Daemon

**Checklist:**
1. Daemon running with `zeroconf` installed: `pip install zeroconf`
2. iPhone and Mac on **same Wi‑Fi network** (mDNS doesn't cross subnets)
3. Local Network permission granted (iOS Settings → CodexMeter → Local Network)
4. Verify mDNS: `dns-sd -B _http._tcp` on macOS should show `codexmeter`

**Debug:**
```bash
# Check mDNS traffic
sudo tcpdump -i en0 port 5353

# Verify daemon is advertising
curl http://localhost:9595/usage
```

## Smoke Test Won't Upload

**Fix:**
1. Hold the AtomS3 button while plugging in USB-C (forces download mode)
2. Try a different USB cable and port
3. Run with verbose output:
   ```bash
   pio run -d firmware -e m5stack_atoms3_smoke -t upload -v
   ```

## Daemon Picks Wrong Serial Port

Specify it explicitly:
```bash
.venv/bin/python daemon/codex-usage-daemon.py --serial-port /dev/cu.usbmodemDC5475CBBC601
```

Or set it permanently in `~/.config/codexmeter/env`:
```
CODEXMETER_SERIAL_PORT=/dev/cu.usbmodemDC5475CBBC601
```

## "Codex auth file is not valid JSON"

`~/.codex/auth.json` is corrupted or empty.

**Fix:** Quit and restart Codex to regenerate the auth file, or delete `~/.codex/auth.json` and log in again.

## Daemon Logs

| OS | stdout | stderr |
|---|---|---|
| macOS | `~/Library/Logs/codexmeter.log` | `~/Library/Logs/codexmeter.err.log` |
| Linux | `journalctl --user -u codex-usage-daemon` | same |

## Still Stuck?

- Run `bash doctor.sh` — the health checker catches most setup issues
- Check the [end-to-end testing guide](https://github.com/BlockedPath/CodexMeter/blob/main/docs/E2E_TESTING.md)
- [Open an issue](https://github.com/BlockedPath/CodexMeter/issues/new/choose) with your OS, Python version, and logs
