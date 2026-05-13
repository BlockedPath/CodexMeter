#!/usr/bin/env python3
"""
CodexMeter host daemon.

Connects to the ESP32 over BLE or USB serial and writes compact usage JSON.
Primary source is the logged-in Codex/ChatGPT OAuth usage endpoint. If that is
unavailable, OpenAI organization cost data and a local Codex activity fallback
keep the display alive.
"""

from __future__ import annotations

import argparse
import asyncio
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import ssl
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover - user-facing dependency hint
    BleakClient = None
    BleakScanner = None

try:
    import serial
except ImportError:  # pragma: no cover - user-facing dependency hint
    serial = None

try:
    import certifi
except ImportError:  # pragma: no cover - system Python often has a usable store
    certifi = None


CACHE_DIR = Path.home() / ".config" / "codexmeter"
ENV_FILE = CACHE_DIR / "env"


def load_env_file() -> None:
    if not ENV_FILE.exists():
        return
    for raw_line in ENV_FILE.read_text(errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file()

DEVICE_NAME = os.getenv("CODEXMETER_DEVICE_NAME", "Codex Controller")
SERVICE_UUID = "434f4445-584d-4554-4552-000000000001"
RX_CHAR_UUID = "434f4445-584d-4554-4552-000000000002"
REQ_CHAR_UUID = "434f4445-584d-4554-4552-000000000004"

POLL_INTERVAL = int(os.getenv("CODEXMETER_POLL_INTERVAL", "60"))
SCAN_TIMEOUT = float(os.getenv("CODEXMETER_SCAN_TIMEOUT", "10"))
DAILY_BUDGET_USD = float(os.getenv("CODEXMETER_DAILY_BUDGET_USD", "10"))
WEEKLY_BUDGET_USD = float(os.getenv("CODEXMETER_WEEKLY_BUDGET_USD", "50"))
LOCAL_DAILY_SESSION_BUDGET = int(os.getenv("CODEXMETER_LOCAL_DAILY_SESSIONS", "12"))
LOCAL_WEEKLY_SESSION_BUDGET = int(os.getenv("CODEXMETER_LOCAL_WEEKLY_SESSIONS", "60"))

ADDRESS_FILE = CACHE_DIR / "ble-address"
OPENAI_COSTS_URL = "https://api.openai.com/v1/organization/costs"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CODEX_AUTH_FILE = Path(os.getenv("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"
SERIAL_PATTERNS = (
    "/dev/cu.usbmodemDC5475CBBC601",
    "/dev/cu.usbmodem*",
    "/dev/ttyACM*",
    "/dev/ttyUSB*",
)


def urlopen_json(req: urllib.request.Request, timeout: int = 20) -> dict:
    context = ssl.create_default_context(cafile=certifi.where()) if certifi else None
    with urllib.request.urlopen(req, timeout=timeout, context=context) as resp:
        return json.loads(resp.read().decode("utf-8"))


@dataclass
class UsageSnapshot:
    session_pct: int
    session_reset_mins: int
    weekly_pct: int
    weekly_reset_mins: int
    status: str
    ok: bool

    def payload(self) -> str:
        return json.dumps(
            {
                "s": self.session_pct,
                "sr": self.session_reset_mins,
                "w": self.weekly_pct,
                "wr": self.weekly_reset_mins,
                "st": self.status,
                "ok": self.ok,
            },
            separators=(",", ":"),
        )


def log(message: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {message}", flush=True)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def next_local_midnight_minutes() -> int:
    now = datetime.now().astimezone()
    tomorrow = (now + timedelta(days=1)).date()
    reset = datetime.combine(tomorrow, datetime.min.time(), tzinfo=now.tzinfo)
    return max(0, round((reset - now).total_seconds() / 60))


def next_local_monday_minutes() -> int:
    now = datetime.now().astimezone()
    days = (7 - now.weekday()) % 7
    if days == 0:
        days = 7
    reset_date = (now + timedelta(days=days)).date()
    reset = datetime.combine(reset_date, datetime.min.time(), tzinfo=now.tzinfo)
    return max(0, round((reset - now).total_seconds() / 60))


def bounded_pct(value: float, budget: float) -> int:
    if budget <= 0:
        return 0
    return max(0, min(100, round((value / budget) * 100)))


def openai_costs(start: datetime, end: datetime, bucket_width: str) -> float:
    api_key = os.getenv("OPENAI_ADMIN_KEY") or os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_ADMIN_KEY is not set")

    query = urllib.parse.urlencode(
        {
            "start_time": int(start.timestamp()),
            "end_time": int(end.timestamp()),
            "bucket_width": bucket_width,
        }
    )
    req = urllib.request.Request(
        f"{OPENAI_COSTS_URL}?{query}",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        data = urlopen_json(req)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI costs API HTTP {exc.code}: {body[:240]}") from exc

    total = 0.0
    for bucket in data.get("data", []):
        for result in bucket.get("results", []):
            amount = result.get("amount", {})
            total += float(amount.get("value") or 0)
    return total


def openai_usage_snapshot() -> UsageSnapshot:
    now = utc_now()
    local_now = datetime.now().astimezone()
    day_start_local = datetime.combine(local_now.date(), datetime.min.time(), tzinfo=local_now.tzinfo)
    week_start_local = day_start_local - timedelta(days=local_now.weekday())

    day_cost = openai_costs(day_start_local.astimezone(timezone.utc), now, "1d")
    week_cost = openai_costs(week_start_local.astimezone(timezone.utc), now, "1d")

    return UsageSnapshot(
        session_pct=bounded_pct(day_cost, DAILY_BUDGET_USD),
        session_reset_mins=next_local_midnight_minutes(),
        weekly_pct=bounded_pct(week_cost, WEEKLY_BUDGET_USD),
        weekly_reset_mins=next_local_monday_minutes(),
        status=f"${day_cost:.2f} today",
        ok=True,
    )


def codex_auth_tokens() -> dict:
    if not CODEX_AUTH_FILE.exists():
        raise RuntimeError(f"Codex auth file not found: {CODEX_AUTH_FILE}")
    try:
        data = json.loads(CODEX_AUTH_FILE.read_text(errors="replace"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Codex auth file is not valid JSON: {exc}") from exc
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        raise RuntimeError("Codex auth file has no tokens object")
    access_token = str(tokens.get("access_token") or "")
    if not access_token:
        raise RuntimeError("Codex auth file has no access_token")
    return tokens


def reset_mins_from_window(window: dict | None) -> int:
    if not isinstance(window, dict):
        return -1
    reset_after = window.get("reset_after_seconds")
    if reset_after is not None:
        try:
            return max(0, round(float(reset_after) / 60))
        except (TypeError, ValueError):
            pass
    reset_at = window.get("reset_at")
    if reset_at is not None:
        try:
            return max(0, round((float(reset_at) - time.time()) / 60))
        except (TypeError, ValueError):
            pass
    return -1


def remaining_pct_from_window(window: dict | None) -> int:
    if not isinstance(window, dict):
        return 0
    try:
        used = float(window.get("used_percent") or 0)
    except (TypeError, ValueError):
        used = 0
    return max(0, min(100, round(100 - used)))


def codex_oauth_usage_snapshot() -> UsageSnapshot:
    tokens = codex_auth_tokens()
    headers = {
        "Authorization": f"Bearer {tokens['access_token']}",
        "Accept": "application/json",
        "User-Agent": "CodexMeter",
    }
    account_id = tokens.get("account_id")
    if account_id:
        headers["ChatGPT-Account-Id"] = str(account_id)

    req = urllib.request.Request(CODEX_USAGE_URL, headers=headers)
    try:
        data = urlopen_json(req)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Codex usage API HTTP {exc.code}: {body[:240]}") from exc

    rate_limit = data.get("rate_limit") if isinstance(data, dict) else {}
    primary = rate_limit.get("primary_window") if isinstance(rate_limit, dict) else None
    secondary = rate_limit.get("secondary_window") if isinstance(rate_limit, dict) else None
    credits = data.get("credits") if isinstance(data, dict) else {}
    balance = credits.get("balance") if isinstance(credits, dict) else None
    try:
        credits_remaining = float(balance)
        status = f"{credits_remaining:.0f} credits"
    except (TypeError, ValueError):
        plan = str(data.get("plan_type") or "codex") if isinstance(data, dict) else "codex"
        status = plan

    return UsageSnapshot(
        session_pct=remaining_pct_from_window(primary),
        session_reset_mins=reset_mins_from_window(primary),
        weekly_pct=remaining_pct_from_window(secondary),
        weekly_reset_mins=reset_mins_from_window(secondary),
        status=status[:24],
        ok=True,
    )


def parse_iso(value: str) -> datetime | None:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value).astimezone(timezone.utc)
    except ValueError:
        return None


def local_codex_activity_snapshot() -> UsageSnapshot:
    index = Path.home() / ".codex" / "session_index.jsonl"
    now = utc_now()
    day_start = datetime.combine(datetime.now().astimezone().date(), datetime.min.time()).astimezone()
    week_start = day_start - timedelta(days=datetime.now().astimezone().weekday())
    day_count = 0
    week_count = 0

    if index.exists():
        for line in index.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            updated = parse_iso(str(row.get("updated_at", "")))
            if not updated:
                continue
            if updated >= day_start.astimezone(timezone.utc):
                day_count += 1
            if updated >= week_start.astimezone(timezone.utc):
                week_count += 1

    return UsageSnapshot(
        session_pct=0,
        session_reset_mins=next_local_midnight_minutes(),
        weekly_pct=0,
        weekly_reset_mins=next_local_monday_minutes(),
        status=f"{day_count}d/{week_count}w sessions",
        ok=False,
    )


def usage_snapshot() -> UsageSnapshot:
    try:
        return codex_oauth_usage_snapshot()
    except Exception as exc:
        log(f"Codex OAuth usage unavailable: {exc}")
    try:
        return openai_usage_snapshot()
    except Exception as exc:
        log(f"OpenAI usage unavailable, using local Codex activity: {exc}")
        return local_codex_activity_snapshot()


def save_address(address: str) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    ADDRESS_FILE.write_text(address + "\n")


def load_address() -> str | None:
    if not ADDRESS_FILE.exists():
        return None
    value = ADDRESS_FILE.read_text().strip()
    return value or None


async def find_device():
    cached = load_address()
    if cached:
        log(f"Trying cached BLE address {cached}")
        return cached

    log(f"Scanning for '{DEVICE_NAME}'...")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: d.name == DEVICE_NAME or ad.local_name == DEVICE_NAME,
        timeout=SCAN_TIMEOUT,
    )
    if not device:
        raise RuntimeError(f"Could not find BLE device named {DEVICE_NAME!r}")
    save_address(device.address)
    log(f"Found {device.name or DEVICE_NAME} at {device.address}")
    return device.address


async def run_once(address: str) -> None:
    async with BleakClient(address) as client:
        log("Connected")
        last_poll = 0.0
        refresh_requested = asyncio.Event()

        def on_refresh(_sender, _data):
            refresh_requested.set()

        try:
            await client.start_notify(REQ_CHAR_UUID, on_refresh)
        except Exception as exc:
            log(f"Refresh notifications unavailable: {exc}")

        while client.is_connected:
            now = time.monotonic()
            if refresh_requested.is_set() or now - last_poll >= POLL_INTERVAL:
                refresh_requested.clear()
                snapshot = usage_snapshot()
                payload = snapshot.payload()
                log(f"Sending: {payload}")
                await client.write_gatt_char(RX_CHAR_UUID, payload.encode("utf-8"), response=False)
                last_poll = now
            await asyncio.sleep(2)


async def send_ble_once(address: str) -> None:
    snapshot = usage_snapshot()
    payload = snapshot.payload()
    async with BleakClient(address) as client:
        log(f"Connected, sending once: {payload}")
        await client.write_gatt_char(RX_CHAR_UUID, payload.encode("utf-8"), response=False)


def find_serial_port(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    for pattern in SERIAL_PATTERNS:
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[0]
    raise RuntimeError("Could not find AtomS3 serial port")


def open_serial_connection(port: str):
    if serial is None:
        raise RuntimeError("Missing dependency: pip install -r requirements.txt")
    log(f"Opening serial port {port}")
    try:
        subprocess.run(["stty", "-f", port, "115200", "-hupcl", "clocal"], check=False)
    except OSError:
        pass

    return serial.Serial(
        port,
        115200,
        timeout=2,
        write_timeout=2,
        dsrdtr=False,
        rtscts=False,
        exclusive=True,
    )


def write_serial_payload(ser, payload: str) -> None:
    ser.setDTR(False)
    ser.setRTS(False)
    ser.write((payload + "\n").encode("utf-8"))
    ser.flush()
    log(f"Sent over serial: {payload}")


def send_serial_payload(port: str, payload: str) -> None:
    ser = open_serial_connection(port)
    try:
        # Opening USB CDC can reset ESP32-S3 sketches. Give setup() time to
        # redraw the screen before sending the newline-delimited JSON payload.
        time.sleep(5.0)
        write_serial_payload(ser, payload)
        time.sleep(1.0)
    finally:
        try:
            ser.setDTR(False)
            ser.setRTS(False)
        finally:
            ser.close()


async def run_serial_loop(port: str, once: bool) -> int:
    if once:
        snapshot = usage_snapshot()
        send_serial_payload(port, snapshot.payload())
        return 0

    ser = open_serial_connection(port)
    try:
        time.sleep(5.0)
        while True:
            snapshot = usage_snapshot()
            write_serial_payload(ser, snapshot.payload())
            await asyncio.sleep(POLL_INTERVAL)
    finally:
        try:
            ser.setDTR(False)
            ser.setRTS(False)
        finally:
            ser.close()


async def main() -> int:
    parser = argparse.ArgumentParser(description="Send OpenAI/Codex usage to CodexMeter.")
    parser.add_argument("--once", action="store_true", help="send one payload then exit")
    parser.add_argument("--print", action="store_true", help="print the current payload and exit")
    parser.add_argument(
        "--transport",
        choices=("ble", "serial"),
        default=os.getenv("CODEXMETER_TRANSPORT", "serial"),
        help="host link to use (default: serial)",
    )
    parser.add_argument("--serial-port", default=os.getenv("CODEXMETER_SERIAL_PORT"), help="serial port for USB mode")
    args = parser.parse_args()

    if args.print:
        print(usage_snapshot().payload())
        return 0

    if args.transport == "serial":
        try:
            return await run_serial_loop(find_serial_port(args.serial_port), args.once)
        except Exception as exc:
            log(f"Serial error: {exc}")
            return 2

    if BleakClient is None or BleakScanner is None:
        print("Missing BLE dependency: pip install -r requirements.txt", file=sys.stderr)
        return 2

    backoff = 1
    while True:
        try:
            address = await find_device()
            if args.once:
                await send_ble_once(address)
                return 0
            await run_once(address)
            backoff = 1
        except KeyboardInterrupt:
            return 0
        except Exception as exc:
            log(f"Disconnected/error: {exc}")
            if ADDRESS_FILE.exists():
                ADDRESS_FILE.unlink()
            log(f"Retrying in {backoff}s")
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
