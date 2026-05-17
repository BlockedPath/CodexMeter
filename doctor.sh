#!/usr/bin/env bash
# doctor.sh — CodexMeter pre-flight health checker
#
# Prints a ✓/⚠/✗ status for every component of the CodexMeter setup and
# exits 1 if any *required* check fails (warnings are non-fatal).
#
# Usage:
#   bash doctor.sh          # normal run
#   NO_COLOR=1 doctor.sh    # plain-text output (no ANSI)
#
# set -u  catches unset variables.
# set -o pipefail  surfaces failures inside pipelines.
# Deliberately NO set -e — we handle per-check errors ourselves.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Colour helpers — disabled when NO_COLOR is set or stdout isn't a tty
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[0;31m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_GREEN='' C_YELLOW='' C_RED='' C_CYAN='' C_BOLD='' C_RST=''
fi

PASS=0; WARN=0; FAIL=0

ok()   { printf '%s✓%s %s\n'   "$C_GREEN"  "$C_RST" "$*"; PASS=$((PASS + 1)); }
warn() { printf '%s⚠%s  %s\n'  "$C_YELLOW" "$C_RST" "$*"; WARN=$((WARN + 1)); }
fail() { printf '%s✗%s %s\n'   "$C_RED"    "$C_RST" "$*"; FAIL=$((FAIL + 1)); }
info() { printf '%sℹ%s  %s\n'  "$C_CYAN"   "$C_RST" "$*"; }

printf '\n%s=== CodexMeter Doctor ===%s\n\n' "$C_BOLD" "$C_RST"

# ---------------------------------------------------------------------------
# Shared paths (resolved once, referenced throughout)
# ---------------------------------------------------------------------------
VENV_PY="$SCRIPT_DIR/.venv/bin/python"
VENV_PIO="$SCRIPT_DIR/.venv/bin/platformio"
PIO_HOME_PIO="${HOME}/.platformio/penv/bin/pio"
PIO_CMD=""       # resolved in check #4, used in check #5
PIP_PY="python3" # default; overridden in check #2 if venv exists

# ---------------------------------------------------------------------------
# 1. Python 3.10+  (REQUIRED)
# ---------------------------------------------------------------------------
printf '%s[1/10]%s Python 3.10+\n' "$C_BOLD" "$C_RST"
if ! command -v python3 &>/dev/null; then
  fail "Python 3: not found — install Python 3.10+ from https://python.org"
else
  _pyver=$(python3 --version 2>&1 | awk '{print $2}')
  _pymaj=$(printf '%s' "$_pyver" | cut -d. -f1)
  _pymin=$(printf '%s' "$_pyver" | cut -d. -f2)
  if [[ "$_pymaj" -lt 3 ]] || [[ "$_pymaj" -eq 3 && "$_pymin" -lt 10 ]]; then
    fail "Python 3: $_pyver — need ≥ 3.10 (required)"
  else
    ok "Python 3: $_pyver"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Virtual env  (WARN)
# ---------------------------------------------------------------------------
printf '%s[2/10]%s Virtual env\n' "$C_BOLD" "$C_RST"
if [[ -x "$VENV_PY" ]]; then
  ok "Virtual env: .venv/bin/python exists"
  PIP_PY="$VENV_PY"
else
  warn "Virtual env: .venv not found — run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
fi

# ---------------------------------------------------------------------------
# 3. Python deps  (WARN)
# ---------------------------------------------------------------------------
printf '%s[3/10]%s Python deps\n' "$C_BOLD" "$C_RST"
_missing_deps=()
for _pkg in bleak pyserial zeroconf certifi; do
  if ! "$PIP_PY" -m pip show "$_pkg" &>/dev/null; then
    _missing_deps+=("$_pkg")
  fi
done
if [[ ${#_missing_deps[@]} -eq 0 ]]; then
  ok "Python deps: bleak pyserial zeroconf certifi — all present"
else
  warn "Python deps: missing packages — ${_missing_deps[*]}"
  warn "  → run: pip install -r requirements.txt  (or .venv/bin/pip install -r requirements.txt)"
fi

# ---------------------------------------------------------------------------
# 4. PlatformIO  (WARN)
# ---------------------------------------------------------------------------
printf '%s[4/10]%s PlatformIO\n' "$C_BOLD" "$C_RST"
if [[ -x "$VENV_PIO" ]]; then
  PIO_CMD="$VENV_PIO"
elif [[ -x "$PIO_HOME_PIO" ]]; then
  PIO_CMD="$PIO_HOME_PIO"
elif command -v platformio &>/dev/null; then
  PIO_CMD="$(command -v platformio)"
elif command -v pio &>/dev/null; then
  PIO_CMD="$(command -v pio)"
fi

if [[ -n "$PIO_CMD" ]]; then
  ok "PlatformIO: $PIO_CMD"
else
  warn "PlatformIO: not found — run: pip install platformio  (or see https://platformio.org/install)"
fi

# ---------------------------------------------------------------------------
# 5. AtomS3 port (VID:PID 303A:1001)  (WARN — device may not be plugged in)
# ---------------------------------------------------------------------------
printf '%s[5/10]%s AtomS3 USB port\n' "$C_BOLD" "$C_RST"
_atom_port=""

# Preferred: platformio device list (shows VID:PID clearly)
if [[ -n "$PIO_CMD" ]]; then
  if "$PIO_CMD" device list 2>/dev/null | grep -qiE '303[Aa]:1001'; then
    _atom_port="detected via 'platformio device list' (VID:PID 303A:1001)"
  fi
fi

# Fallback: glob common serial-port paths
if [[ -z "$_atom_port" ]]; then
  for _g in /dev/cu.usbmodem* /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$_g" ]] && { _atom_port="$_g"; break; }
  done
fi

if [[ -n "$_atom_port" ]]; then
  ok "AtomS3 port: $_atom_port"
else
  warn "AtomS3 port: not detected — is the device plugged in?"
  warn "  → expected VID:PID 303A:1001 (M5Stack AtomS3)"
fi

# ---------------------------------------------------------------------------
# 6. Codex auth  (WARN)
# ---------------------------------------------------------------------------
printf '%s[6/10]%s Codex auth\n' "$C_BOLD" "$C_RST"
_codex_auth="${HOME}/.codex/auth.json"
if [[ -f "$_codex_auth" && -s "$_codex_auth" ]]; then
  ok "Codex auth: ~/.codex/auth.json exists and is non-empty"
else
  warn "Codex auth: ~/.codex/auth.json not found or empty"
  warn "  → daemon will fall back to session counting via ~/.codex/session_index.jsonl"
fi

# ---------------------------------------------------------------------------
# 7. OPENAI_ADMIN_KEY or OPENAI_API_KEY  (WARN)
# ---------------------------------------------------------------------------
printf '%s[7/10]%s OpenAI API key\n' "$C_BOLD" "$C_RST"
_cm_env_file="${HOME}/.config/codexmeter/env"
_has_key=false

if [[ -n "${OPENAI_ADMIN_KEY:-}" || -n "${OPENAI_API_KEY:-}" ]]; then
  _has_key=true
elif [[ -f "$_cm_env_file" ]]; then
  # Look for a non-commented, non-empty key assignment in the env file
  if grep -qE '^\s*(OPENAI_ADMIN_KEY|OPENAI_API_KEY)\s*=\s*\S' "$_cm_env_file" 2>/dev/null; then
    _has_key=true
  fi
fi

if [[ "$_has_key" == true ]]; then
  ok "OpenAI key: OPENAI_ADMIN_KEY or OPENAI_API_KEY is configured"
else
  warn "OpenAI key: neither OPENAI_ADMIN_KEY nor OPENAI_API_KEY is set"
  warn "  → cost API disabled; daemon will use fallback session counting"
  warn "  → set a key in ~/.config/codexmeter/env or export it before running the daemon"
fi

# ---------------------------------------------------------------------------
# 8. Daemon env file  (INFO)
# ---------------------------------------------------------------------------
printf '%s[8/10]%s Daemon env file\n' "$C_BOLD" "$C_RST"
if [[ -f "$_cm_env_file" ]]; then
  ok "Daemon env file: ~/.config/codexmeter/env exists"
else
  info "Daemon env file: ~/.config/codexmeter/env not found — run install.sh to create it"
fi

# ---------------------------------------------------------------------------
# 9. macOS LaunchAgent  (INFO — macOS only)
# ---------------------------------------------------------------------------
_os="$(uname -s)"

printf '%s[9/10]%s macOS LaunchAgent\n' "$C_BOLD" "$C_RST"
if [[ "$_os" == "Darwin" ]]; then
  _plist="${HOME}/Library/LaunchAgents/com.justin.codexmeter.plist"
  if [[ -f "$_plist" ]]; then
    ok "macOS LaunchAgent: com.justin.codexmeter.plist installed"
    if launchctl list 2>/dev/null | grep -q "codexmeter"; then
      ok "macOS LaunchAgent: service is loaded and running"
    else
      info "macOS LaunchAgent: plist present but service not loaded"
      info "  → run: launchctl load \"$_plist\""
    fi
  else
    info "macOS LaunchAgent: not installed — run install.sh"
  fi
else
  info "macOS LaunchAgent: skipped (not macOS)"
fi

# ---------------------------------------------------------------------------
# 10. Linux systemd service  (INFO — Linux only)
# ---------------------------------------------------------------------------
printf '%s[10/10]%s Linux systemd service\n' "$C_BOLD" "$C_RST"
if [[ "$_os" == "Linux" ]]; then
  if systemctl --user is-active codex-usage-daemon &>/dev/null; then
    ok "Linux systemd: codex-usage-daemon is active"
  else
    _svc_status="$(systemctl --user is-active codex-usage-daemon 2>/dev/null || true)"
    case "${_svc_status:-unknown}" in
      inactive|failed|unknown|"")
        info "Linux systemd: codex-usage-daemon not installed or inactive — run install.sh"
        ;;
      *)
        info "Linux systemd: codex-usage-daemon status: $_svc_status"
        ;;
    esac
  fi
else
  info "Linux systemd: skipped (not Linux)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s─────────────────────────────────────%s\n' "$C_BOLD" "$C_RST"
printf '%sSummary:%s  %s%d passed%s  %s%d warnings%s  %s%d failed%s\n' \
  "$C_BOLD"   "$C_RST" \
  "$C_GREEN"  "$PASS"  "$C_RST" \
  "$C_YELLOW" "$WARN"  "$C_RST" \
  "$C_RED"    "$FAIL"  "$C_RST"
printf '%s─────────────────────────────────────%s\n\n' "$C_BOLD" "$C_RST"

if [[ "$FAIL" -gt 0 ]]; then
  printf '%sOne or more required checks failed. See ✗ lines above.%s\n\n' "$C_RED" "$C_RST"
  exit 1
fi
exit 0
