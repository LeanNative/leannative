"""Unit tests for framework/native/ci/sim-screens, the simulator screen ui-tests records.

The listings are `xcrun simctl io <udid> enumerate`'s "Connected Screens", as an iPhone 17 Pro (iOS 27.0)
prints them and as an iPhone Duo (iOS 27.1, winnow-lean run 40948152331) did, its second integrated
screen listed before the primary one.
"""
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "native" / "ci" / "sim-screens"
loader = importlib.machinery.SourceFileLoader("sim_screens", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
ss = importlib.util.module_from_spec(spec)
loader.exec_module(ss)


def screen(n, name, device, kind, size):
    return (f"    ({n}) {name}:\n        Screen ID: {n}\n        Name: {name}\n        Unique ID: 00000000-0000-0000-0000-00000000000{n}\n"
            f"        Device Name: {device}\n        Seed: 3\n        Screen Type: {kind}\n        Pixel Size: {size}\n"
            f"        Preferred UI Scale: 3\n")


def listing(*screens):
    # a display port first: its keys (Default width, …) are not a screen's
    return ("Port:\n    UUID: 3E90EFFF-21C0-4979-82C5-60481C100647\n    Class: Display\n    Power state: On\n"
            "    Default width: 720\n    Default height: 480\n\nPort:\n    Class: DisplayAdapter\n"
            "    Creatable Screen Properties:\n    Connected Screens:\n" + "".join(screens) + "    Power state: On\n")


IPHONE_17_PRO = listing(screen(1, "LCD", "primary", "Integrated", "{1206, 2622}"),
                        screen(2, "TVOut", "external-0", "TVOut", "{720, 480}"),
                        screen(4, "Resizable", "resizable", "Scene", "{7680, 4320}"),
                        screen(3, "Wireless", "wireless0", "CarPlay", "{720, 480}"))
IPHONE_DUO = listing(screen(3, "LCD-1", "primary-1", "Integrated", "{2007, 2853}"),
                     screen(1, "LCD", "primary", "Integrated", "{1398, 2034}"),
                     screen(2, "TVOut", "external-0", "TVOut", "{720, 480}"))


class SimScreensTests(unittest.TestCase):
    def run_script(self, text):
        with tempfile.TemporaryDirectory() as d:
            record = Path(d) / "record.json"
            out = subprocess.run([sys.executable, "-I", str(SCRIPT), str(record)], input=text, text=True,
                                 capture_output=True, check=True).stdout
            return out.strip(), json.loads(record.read_text())

    def test_a_phone_records_its_screen(self):
        chosen, record = self.run_script(IPHONE_17_PRO)
        self.assertEqual(chosen, "1")
        self.assertEqual(record["recorded"], "1")
        self.assertEqual([s["screen_type"] for s in record["screens"]], ["Integrated", "TVOut", "Scene", "CarPlay"])
        self.assertEqual(record["screens"][0]["pixel_size"], "{1206, 2622}")

    def test_two_integrated_screens_the_primary_one(self):
        # the Duo lists its second screen first: that one gave a single 2007x2853 frame for a whole journey
        chosen, record = self.run_script(IPHONE_DUO)
        self.assertEqual(chosen, "1")
        self.assertEqual(next(s for s in record["screens"] if s["id"] == chosen)["device_name"], "primary")

    def test_no_primary_the_first_integrated(self):
        chosen, _ = self.run_script(listing(screen(2, "TVOut", "external-0", "TVOut", "{720, 480}"),
                                            screen(5, "Panel", "panel", "Integrated", "{100, 200}")))
        self.assertEqual(chosen, "5")

    def test_nothing_listed_lets_recordvideo_choose(self):
        chosen, record = self.run_script("An error was encountered processing the command\n")
        self.assertEqual(chosen, "")
        self.assertEqual(record, {"screens": [], "recorded": None})

    def test_port_keys_are_not_screens(self):
        self.assertEqual([s["id"] for s in ss.screens(IPHONE_17_PRO)], ["1", "2", "4", "3"])


if __name__ == "__main__":
    unittest.main()
