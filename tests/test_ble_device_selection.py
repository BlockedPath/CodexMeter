import importlib.util
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

REPO_ROOT = Path(__file__).resolve().parents[1]
DAEMON_PATH = REPO_ROOT / "daemon" / "codex-usage-daemon.py"


def load_daemon():
    spec = importlib.util.spec_from_file_location("codex_usage_daemon", DAEMON_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeDevice:
    def __init__(self, address, name="Codex Controller", local_name=None):
        self.address = address
        self.name = name
        self.local_name = local_name


class FakeClient:
    attempts = []
    verified_addresses = set()
    fail_addresses = set()
    on_enter = None

    def __init__(self, address):
        self.address = address
        self.services = []
        self.is_connected = False

    async def __aenter__(self):
        type(self).attempts.append(self.address)
        if type(self).on_enter:
            type(self).on_enter(self.address)
        if self.address in type(self).fail_addresses:
            raise RuntimeError("stale BLE address")
        self.is_connected = True
        self.services = [
            SimpleNamespace(
                uuid="434f4445-584d-4554-4552-000000000001",
                characteristics=[
                    SimpleNamespace(uuid="434f4445-584d-4554-4552-000000000002")
                ],
            )
        ]
        type(self).verified_addresses.add(self.address)
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self.is_connected = False

    async def get_services(self):
        return self.services


class FakeScanner:
    devices = []
    find_device_by_filter_called = False
    discover_called = False

    @classmethod
    async def discover(cls, timeout):
        cls.discover_called = True
        return cls.devices

    @classmethod
    async def find_device_by_filter(cls, filterfunc, timeout):
        cls.find_device_by_filter_called = True
        for device in cls.devices:
            adv = SimpleNamespace(local_name=device.local_name)
            if filterfunc(device, adv):
                return device
        return None


class BleDeviceSelectionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.daemon = load_daemon()
        self.tmpdir = TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.address_file = Path(self.tmpdir.name) / "ble-address"
        self.daemon.ADDRESS_FILE = self.address_file
        self.daemon.CACHE_DIR = self.address_file.parent
        self.daemon.BleakClient = FakeClient
        self.daemon.BleakScanner = FakeScanner
        self.daemon.SCAN_TIMEOUT = 0.01
        FakeClient.attempts = []
        FakeClient.verified_addresses = set()
        FakeClient.fail_addresses = set()
        FakeClient.on_enter = None
        FakeScanner.devices = []
        FakeScanner.find_device_by_filter_called = False
        FakeScanner.discover_called = False

    async def test_cached_address_is_verified_before_use(self):
        self.address_file.write_text("AA:BB:CC\n")

        address = await self.daemon.find_device()

        self.assertEqual(address, "AA:BB:CC")
        self.assertEqual(FakeClient.attempts, ["AA:BB:CC"])
        self.assertIn("AA:BB:CC", FakeClient.verified_addresses)
        self.assertFalse(FakeScanner.discover_called)
        self.assertFalse(FakeScanner.find_device_by_filter_called)

    async def test_stale_cached_address_is_removed_and_scan_is_used(self):
        self.address_file.write_text("STALE\n")
        FakeClient.fail_addresses = {"STALE"}
        FakeScanner.devices = [FakeDevice("FRESH")]

        address = await self.daemon.find_device()

        self.assertEqual(address, "FRESH")
        self.assertEqual(FakeClient.attempts, ["STALE", "FRESH"])
        self.assertIn("FRESH", FakeClient.verified_addresses)
        self.assertEqual(self.address_file.read_text().strip(), "FRESH")
        self.assertTrue(FakeScanner.discover_called)

    async def test_ambiguous_ble_name_matches_fail_without_saving(self):
        FakeScanner.devices = [
            FakeDevice("ONE"),
            FakeDevice("TWO"),
        ]

        with self.assertRaisesRegex(RuntimeError, "multiple|ambiguous"):
            await self.daemon.find_device()

        self.assertFalse(self.address_file.exists())
        self.assertEqual(FakeClient.attempts, [])
        self.assertTrue(FakeScanner.discover_called)

    async def test_single_scanned_match_is_verified_before_saving(self):
        FakeScanner.devices = [FakeDevice("ONLY")]
        verified_during_scan = []

        def record_cache_state(address):
            if address == "ONLY":
                verified_during_scan.append(self.address_file.exists())

        FakeClient.on_enter = record_cache_state

        address = await self.daemon.find_device()

        self.assertEqual(address, "ONLY")
        self.assertEqual(FakeClient.attempts, ["ONLY"])
        self.assertEqual(verified_during_scan, [False])
        self.assertEqual(self.address_file.read_text().strip(), "ONLY")
        self.assertTrue(FakeScanner.discover_called)


if __name__ == "__main__":
    unittest.main()
