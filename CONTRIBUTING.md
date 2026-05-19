# Contributing to CodexMeter

Thanks for your interest in contributing! CodexMeter is a personal project, but
bug reports, fixes, and improvements are welcome.

## Getting Started

1. Fork the repo and clone your fork.
2. Follow the [README setup guide](README.md#quick-start--full-setup) to get
   everything running locally.
3. Run the health check: `bash doctor.sh`

## Development Workflow

### Firmware (C++ / ESP32-S3)

```bash
cd firmware
pio run -e m5stack_atoms3          # build
pio run -e m5stack_atoms3_smoke    # build smoke test
```

Format with `clang-format` if available. The codebase targets Arduino framework
on ESP32-S3 with C++17.

### Daemon (Python 3.10+)

```bash
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m ruff check .          # lint
.venv/bin/python -m pytest -q             # test
.venv/bin/python -m black .               # format
```

### iOS App (Swift)

```bash
cd ios/CodexMeterApp
xcodegen generate
open CodexMeterApp.xcodeproj
```

Use Xcode 16.0+. The project file is generated from `project.yml` — do not edit
the `.xcodeproj` directly.

## Pull Requests

- Keep PRs focused — one feature or fix per PR.
- Run `ruff` and `pytest` before submitting Python changes.
- Verify the firmware builds with `pio run -e m5stack_atoms3`.
- If adding new features, update the README or [systm.md](systm.md) as needed.

## Reporting Bugs

Open an issue with:

- Your OS and Python version (`python3 --version`)
- Daemon output or logs
- Steps to reproduce
- Whether the issue is with the firmware, daemon, or iOS app

## Style

- Python: follow `ruff` defaults and `black` formatting
- C++: match the existing style in `firmware/src/`
- Swift: follow standard Swift conventions, use the project's existing patterns
- Commits: prefer [conventional commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `chore:`)
