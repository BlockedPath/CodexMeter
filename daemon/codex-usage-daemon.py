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
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import ssl
from dataclasses import dataclass, replace
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
ACTIVITY_POLL_INTERVAL = float(os.getenv("CODEXMETER_ACTIVITY_POLL_INTERVAL", "2"))
SCAN_TIMEOUT = float(os.getenv("CODEXMETER_SCAN_TIMEOUT", "10"))
DAILY_BUDGET_USD = float(os.getenv("CODEXMETER_DAILY_BUDGET_USD", "10"))
WEEKLY_BUDGET_USD = float(os.getenv("CODEXMETER_WEEKLY_BUDGET_USD", "50"))
LOCAL_DAILY_SESSION_BUDGET = int(os.getenv("CODEXMETER_LOCAL_DAILY_SESSIONS", "12"))
LOCAL_WEEKLY_SESSION_BUDGET = int(os.getenv("CODEXMETER_LOCAL_WEEKLY_SESSIONS", "60"))

ADDRESS_FILE = CACHE_DIR / "ble-address"
OPENAI_COSTS_URL = "https://api.openai.com/v1/organization/costs"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CODEX_AUTH_FILE = Path(os.getenv("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"
CODEX_HOME = Path(os.getenv("CODEX_HOME", str(Path.home() / ".codex")))
CODEX_SESSIONS_DIR = CODEX_HOME / "sessions"
CODEX_SESSION_INDEX = CODEX_HOME / "session_index.jsonl"
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
    pet_title: str = ""
    pet_message: str = ""

    def payload(self) -> str:
        data = {
            "s": self.session_pct,
            "sr": self.session_reset_mins,
            "w": self.weekly_pct,
            "wr": self.weekly_reset_mins,
            "st": self.status,
            "ok": self.ok,
        }
        if self.pet_title:
            data["pt"] = compact_text(self.pet_title, 26)
        if self.pet_message:
            data["m"] = compact_text(self.pet_message, 42)
        return json.dumps(data, separators=(",", ":"))


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


def latest_session_file() -> Path | None:
    if not CODEX_SESSIONS_DIR.exists():
        return None
    latest: tuple[float, Path] | None = None
    for path in CODEX_SESSIONS_DIR.rglob("*.jsonl"):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if latest is None or mtime > latest[0]:
            latest = (mtime, path)
    return latest[1] if latest else None


def compact_text(value: str, limit: int) -> str:
    text = " ".join(str(value or "").split())
    if len(text) <= limit:
        return text
    if limit <= 3:
        return text[:limit]
    return text[: limit - 3].rstrip() + "..."


def tail_text(path: Path, limit: int = 524288) -> str:
    with path.open("rb") as fh:
        try:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - limit))
        except OSError:
            pass
        return fh.read().decode("utf-8", errors="replace")


def session_id_from_path(path: Path) -> str:
    match = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", path.stem)
    return match.group(1) if match else ""


def session_title(session_id: str) -> str:
    if not session_id or not CODEX_SESSION_INDEX.exists():
        return ""
    try:
        for line in CODEX_SESSION_INDEX.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if str(row.get("id") or "") == session_id:
                return compact_text(str(row.get("thread_name") or ""), 26)
    except OSError:
        return ""
    return ""


def message_text(payload: dict) -> str:
    chunks: list[str] = []
    content = payload.get("content")
    if isinstance(content, list):
        for part in content:
            if not isinstance(part, dict):
                continue
            text = part.get("text") or part.get("content")
            if text:
                chunks.append(str(text))
    elif isinstance(content, str):
        chunks.append(content)
    return compact_text(" ".join(chunks), 42)


def task_complete_text(payload: dict) -> str:
    return compact_text(str(payload.get("last_agent_message") or ""), 42)


def command_activity(cmd: str) -> str:
    lowered = cmd.strip().lower()
    first = lowered.split(maxsplit=1)[0] if lowered else ""
    if first in {"rg", "grep", "find", "mdfind"}:
        return "Searching files"
    if first in {"sed", "tail", "head", "cat", "nl", "less"}:
        return "Reading file"
    if first in {"ls", "tree", "pwd"}:
        return "Listing files"
    if "platformio" in lowered or "pio " in lowered:
        return "Building firmware"
    if "git " in lowered:
        return "Checking git"
    return "Running command"


def function_call_activity(name: str, arguments: str) -> str:
    try:
        args = json.loads(arguments)
    except json.JSONDecodeError:
        args = {}
    if name == "exec_command":
        return command_activity(str(args.get("cmd") or ""))
    if name in {"apply_patch"}:
        return "Editing files"
    if name in {"open", "find"}:
        return "Reading docs"
    if name in {"search_query", "web.run"}:
        return "Searching web"
    return "Using tool"


def codex_activity(path: Path | None = None, max_age_seconds: int = 180) -> tuple[str, str]:
    path = path or latest_session_file()
    if path is None:
        return "", ""
    title = session_title(session_id_from_path(path)) or "Codex"
    try:
        raw_lines = tail_text(path).splitlines()
    except OSError:
        return title, ""

    now = utc_now()
    for line in reversed(raw_lines):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = parse_iso(str(row.get("timestamp", "")))
        if ts is not None and (now - ts).total_seconds() > max_age_seconds:
            return title, "Ready"

        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        row_type = row.get("type")

        if row_type == "response_item":
            item_type = payload.get("type")
            if item_type == "function_call":
                return title, function_call_activity(str(payload.get("name") or ""), str(payload.get("arguments") or ""))
            if item_type == "function_call_output":
                return title, "Thinking"
            if item_type == "message":
                phase = str(payload.get("phase") or "")
                if phase in {"final", "final_answer"}:
                    return title, message_text(payload) or "Ready"
                return title, "Thinking"

        if row_type == "event_msg":
            event_type = payload.get("type")
            if event_type == "task_complete":
                return title, task_complete_text(payload) or "Ready"
            if event_type == "agent_message":
                phase = str(payload.get("phase") or "")
                if phase in {"final", "final_answer"}:
                    return title, compact_text(str(payload.get("message") or ""), 42) or "Ready"
                return title, "Thinking"
            if event_type == "token_count":
                return title, "Thinking"

    return title, "Ready"


def with_codex_activity(snapshot: UsageSnapshot) -> UsageSnapshot:
    title, message = codex_activity()
    return replace(snapshot, pet_title=title, pet_message=message)


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
        last_payload = ""
        snapshot = usage_snapshot()
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
                last_poll = now
            payload = with_codex_activity(snapshot).payload()
            if payload != last_payload:
                log(f"Sending: {payload}")
                await client.write_gatt_char(RX_CHAR_UUID, payload.encode("utf-8"), response=False)
                last_payload = payload
            await asyncio.sleep(ACTIVITY_POLL_INTERVAL)


async def send_ble_once(address: str) -> None:
    snapshot = with_codex_activity(usage_snapshot())
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
        snapshot = with_codex_activity(usage_snapshot())
        send_serial_payload(port, snapshot.payload())
        return 0

    ser = open_serial_connection(port)
    try:
        time.sleep(5.0)
        snapshot = usage_snapshot()
        last_poll = time.monotonic()
        last_payload = ""
        while True:
            now = time.monotonic()
            if now - last_poll >= POLL_INTERVAL:
                snapshot = usage_snapshot()
                last_poll = now
            payload = with_codex_activity(snapshot).payload()
            if payload != last_payload:
                write_serial_payload(ser, payload)
                last_payload = payload
            await asyncio.sleep(ACTIVITY_POLL_INTERVAL)
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
        print(with_codex_activity(usage_snapshot()).payload())
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
