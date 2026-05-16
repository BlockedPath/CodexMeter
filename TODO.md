# CodexMeter TODO

## Nice Improvements

- [ ] Add `doctor.sh` to check Python deps, PlatformIO, connected AtomS3 port,
  Codex auth, daemon env, and service status.
- [ ] Add a live serial monitor mode after flashing so boot logs and incoming
  payloads are easy to see.
- [ ] Make the daemon auto-rescan and reconnect when the AtomS3 serial port
  disappears or re-enumerates.
- [x] Add a richer "Now Working On" screen with current project, thread title,
  current action, and last completed action.
- [ ] Add brightness, rotation, and theme config through ESP32 preferences and
  optional payload config fields.
- [ ] Clarify usage labels for Codex primary window, secondary window, API cost
  fallback, and local-only fallback.
- [ ] Add a small macOS menu bar or script menu for daemon controls, flashing,
  test payloads, logs, and current port.
- [ ] Add canned test payload commands such as `happy`, `low`, and `fallback`
  for screenshots and UI validation.
- [ ] Make pet/icon asset generation reproducible from source images.
- [ ] Refresh README screenshots or add a short demo GIF of screen cycling and
  live Codex activity.
