"""Unit tests for framework/native/ci/export-evidence (`make check`: python3 -I -m unittest discover -s scripts/tests).

The result bundle is faked at the xcresulttool boundary (the exporter's `xcresulttool` function), so these
run anywhere; the PNG and MP4 inputs are real files. Carried over from Winnow's prepare-journey-media tests
(winnow-lean ce35d2a, scripts/tests/test_prepare_journey_media.py) and extended to non-passing runs, source
identity, configurable names, the device cross-check and the optional transcoder.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

loader = importlib.machinery.SourceFileLoader(
    "export_evidence", str(Path(__file__).resolve().parents[2] / "native" / "ci" / "export-evidence"))
spec = importlib.util.spec_from_loader(loader.name, loader)
ev = importlib.util.module_from_spec(spec)
loader.exec_module(ev)

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER = "fedcba9876543210fedcba9876543210fedcba98"
PASSING = [("testOne", "passed", "4.100"), ("testTwo", "passed", "2.789")]


def png(width, height, salt=b""):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    raw = b"".join(b"\x00" + bytes(width * 3) for _ in range(height))
    return (ev.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"tEXt", b"salt\x00" + salt) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def mp4(width, height, seconds, padding=0):
    mvhd = box(b"mvhd", bytes(4) + bytes(8) + struct.pack(">II", 1000, int(seconds * 1000)) + bytes(80))
    tkhd = box(b"tkhd", bytes(4) + bytes(72) + struct.pack(">II", width << 16, height << 16))
    return box(b"ftyp", b"isom" + bytes(4)) + box(b"moov", mvhd + box(b"trak", tkhd)) + box(b"mdat", bytes(padding))


def log(tests, end="succeeded", started_only=()):
    lines = ["Test Suite 'AppUITests' started"]
    for name, result, seconds in tests:
        lines += [f"Test Case '-[AppUITests {name}]' started.", f"Test Case '-[AppUITests {name}]' {result} ({seconds} seconds)."]
    for name in started_only:
        lines.append(f"Test Case '-[AppUITests {name}]' started.")
    if end:
        total = sum(float(s) for _, _, s in tests)
        failures = sum(1 for _, r, _ in tests if r == "failed")
        lines.append(f"\t Executed {len(tests)} tests, with {failures} failures (0 unexpected) in {total:.3f} ({total + 0.02:.3f}) seconds")
        lines.append({"succeeded": "** TEST SUCCEEDED **", "failed": "** TEST FAILED **", "both": "** TEST SUCCEEDED **\n** TEST FAILED **"}[end])
    return "\n".join(lines) + "\n"


def args(**overrides):
    values = dict(name=None, screenshots=None, video_out=None, max_video_bytes=25 * 1024 * 1024, transcode="auto",
                  app_metadata=None, source_revision=None, require_passed=False)
    values.update(overrides)
    return argparse.Namespace(**values)


class ExportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.run_dir = self.base / "run"
        (self.run_dir / "screenshots").mkdir(parents=True)
        self.out = self.base / "out"
        self.name = "ui-tests"
        self.shots = {"01-start": png(4, 8, b"a"), "02-done": png(4, 8, b"b")}
        for n, data in self.shots.items():
            (self.run_dir / "screenshots" / f"{n}.png").write_bytes(data)
        self.write_run({"schema": 1, "name": "ui-tests", "scheme": "App", "platform": "iOS Simulator",
                        "started_at": "2026-10-29T10:00:00+00:00", "finished_at": "2026-10-29T10:05:00+00:00", "exit_status": 0,
                        "source": {"revision": SHA, "recorded_by": "git", "dirty": False}, "framework": {"revision": OTHER}})
        (self.run_dir / "device.json").write_text(json.dumps({
            "name": "iPhone 17 Pro", "type": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "os": "iOS 27.0"}))
        self.write_log(log(PASSING))
        self.bundle_tests = [(n, r) for n, r, _ in PASSING]
        self.bundle_device = {"modelName": "iPhone 17 Pro", "osVersion": "27.0", "platform": "iOS Simulator", "architecture": "arm64"}
        self.attached = [("testOne", n, 1.0 + i, d) for i, (n, d) in enumerate(self.shots.items())]
        (self.run_dir / f"{self.name}.xcresult").mkdir()
        (self.run_dir / f"{self.name}.xcresult" / "Info.plist").write_text("bundle")
        self.patch("xcresulttool", self.fake_xcresulttool)
        self.tools = set()
        self.real_which = shutil.which
        self.patch_which()
        # the exporter must never ask git for the tested revision
        real_run = subprocess.run

        def guarded(command, *a, **k):
            if command and command[0] == "git":
                raise AssertionError("export-evidence ran git")
            return real_run(command, *a, **k)
        self.patch_obj(ev.subprocess, "run", guarded)

    # -- fixtures ---------------------------------------------------------------------------------------
    def patch(self, name, value):
        self.patch_obj(ev, name, value)

    def patch_obj(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def patch_which(self):
        self.patch_obj(ev.shutil, "which", lambda name: (self.real_which(name) if name in self.tools else None) if name != "xcrun" else "/usr/bin/xcrun")

    def write_run(self, run):
        (self.run_dir / "run.json").write_text(json.dumps(run))

    def write_log(self, text):
        (self.run_dir / "xcodebuild.log").write_text(text)

    def fake_xcresulttool(self, *arguments):
        if arguments[:3] == ("get", "test-results", "tests"):
            cases = [{"nodeType": "Test Case", "name": n, "nodeIdentifier": f"AppUITests/{n}",
                      "result": {"passed": "Passed", "failed": "Failed", "skipped": "Skipped", "expected": "Expected Failure"}.get(r, r),
                      "durationInSeconds": 1.5} for n, r in self.bundle_tests]
            return json.dumps({"testNodes": [{"nodeType": "Test Plan", "children": [
                {"nodeType": "Test Suite", "name": "AppUITests", "children": cases}]}],
                "devices": [self.bundle_device] if self.bundle_device else []})
        if arguments[:2] == ("export", "attachments"):
            into = Path(arguments[arguments.index("--output-path") + 1])
            entries = {}
            for i, (test, name, stamp, data) in enumerate(self.attached):
                exported = f"export-{i}.png"
                (into / exported).write_bytes(data)
                entries.setdefault(test, []).append({"exportedFileName": exported, "timestamp": stamp,
                    "suggestedHumanReadableName": f"{name}_0_{'%08d' % i}-0000-0000-0000-000000000000.png"})
            (into / "manifest.json").write_text(json.dumps(
                [{"testIdentifier": f"AppUITests/{t}()", "attachments": a} for t, a in entries.items()]))
            return ""
        raise AssertionError(f"unexpected xcresulttool {arguments}")

    def export(self, **overrides):
        return ev.export(self.run_dir, self.out, args(**overrides), now=datetime(2026, 10, 29, 12, 0, tzinfo=timezone.utc))

    def assertFails(self, text, **overrides):
        with self.assertRaises(ev.Failure) as caught:
            self.export(**overrides)
        self.assertIn(text, str(caught.exception))

    # -- a passing run ----------------------------------------------------------------------------------
    def test_passing_run(self):
        evidence = self.export()
        self.assertEqual(evidence["schema"], ev.SCHEMA)
        self.assertEqual(evidence["result"], "passed")
        self.assertEqual(evidence["result_reasons"], [])
        self.assertEqual([t["name"] for t in evidence["tests"]], ["testOne", "testTwo"])
        self.assertEqual(evidence["test_seconds"], 6.889)
        manifest = json.loads((self.out / ev.MANIFEST).read_text())
        self.assertEqual(manifest, evidence)

    def test_screenshots_are_attributed_and_hashed(self):
        evidence = self.export()
        names = [s["name"] for s in evidence["screenshots"]]
        self.assertEqual(names, ["01-start", "02-done"])
        for shot in evidence["screenshots"]:
            data = self.shots[shot["name"]]
            sha = hashlib.sha256(data).hexdigest()
            self.assertEqual((shot["test"], shot["tests"], shot["captures"]), ("testOne", ["testOne"], 1))
            self.assertEqual(shot["original_sha256"], sha)
            self.assertEqual(shot["on_disk_sha256"], sha)
            self.assertEqual(shot["sha256"], sha)
            self.assertEqual((self.out / shot["path"]).read_bytes(), data)
            self.assertEqual((shot["width"], shot["height"]), (4, 8))

    def test_a_screenshot_several_tests_take_is_attributed_to_each_and_the_first_is_copied(self):
        later = png(4, 8, b"later")
        self.attached.append(("testTwo", "02-done", 9.0, later))
        (self.run_dir / "screenshots" / "02-done.png").write_bytes(later)  # the file on disk is the last capture
        shot = [s for s in self.export()["screenshots"] if s["name"] == "02-done"][0]
        self.assertEqual((shot["test"], shot["tests"], shot["captures"]), ("testOne", ["testOne", "testTwo"], 2))
        self.assertEqual((self.out / shot["path"]).read_bytes(), self.shots["02-done"])
        self.assertEqual(shot["on_disk_sha256"], hashlib.sha256(later).hexdigest())

    def test_attachments_without_files_on_disk(self):
        shutil.rmtree(self.run_dir / "screenshots")
        evidence = self.export()
        self.assertEqual(len(evidence["screenshots"]), 2)
        self.assertNotIn("on_disk_sha256", evidence["screenshots"][0])

    def test_artifact_hashes(self):
        evidence = self.export()
        hashes = evidence["artifacts_sha256"]
        for name in ("xcodebuild.log", "device.json", "run.json"):
            self.assertEqual(hashes[name], hashlib.sha256((self.run_dir / name).read_bytes()).hexdigest())
        self.assertEqual(hashes["ui-tests.xcresult"], ev.tree_digest(self.run_dir / "ui-tests.xcresult"))
        (self.run_dir / "ui-tests.xcresult" / "Info.plist").write_text("changed")
        self.assertNotEqual(hashes["ui-tests.xcresult"], ev.tree_digest(self.run_dir / "ui-tests.xcresult"))

    def test_export_time_is_not_run_identity(self):
        evidence = self.export()
        self.assertEqual(evidence["exported"]["at"], "2026-10-29T12:00:00+00:00")
        self.assertEqual(evidence["run"]["started_at"], "2026-10-29T10:00:00+00:00")
        self.assertEqual(evidence["run"]["finished_at"], "2026-10-29T10:05:00+00:00")

    # -- runs that did not pass -------------------------------------------------------------------------
    def test_a_failed_test_is_failed(self):
        self.bundle_tests = [("testOne", "passed"), ("testTwo", "failed")]
        self.write_log(log([("testOne", "passed", "1"), ("testTwo", "failed", "2")], end="failed"))
        evidence = self.export()
        self.assertEqual(evidence["result"], "failed")
        self.assertIn("testTwo", evidence["result_reasons"][0])
        self.assertEqual([t["result"] for t in evidence["tests"]], ["passed", "failed"])

    def test_require_passed_writes_then_exits_3(self):
        self.bundle_tests = [("testOne", "passed"), ("testTwo", "failed")]
        self.write_log(log([("testOne", "passed", "1"), ("testTwo", "failed", "2")], end="failed"))
        with self.assertRaises(SystemExit) as caught:
            ev.main([str(self.run_dir), str(self.out), "--require-passed"])
        self.assertEqual(caught.exception.code, 3)
        self.assertEqual(json.loads((self.out / ev.MANIFEST).read_text())["result"], "failed")

    def test_skipped(self):
        self.bundle_tests = [("testOne", "passed"), ("testTwo", "skipped")]
        self.write_log(log([("testOne", "passed", "1"), ("testTwo", "skipped", "0")]))
        self.assertEqual(self.export()["result"], "skipped")

    def test_expected_failure_is_a_pass_and_keeps_the_bundle_result(self):
        self.bundle_tests = [("testOne", "passed"), ("testTwo", "expected")]
        evidence = self.export()
        self.assertEqual(evidence["result"], "passed")
        self.assertEqual(evidence["tests"][1]["bundle_result"], "Expected Failure")

    def test_a_log_without_an_end_is_incomplete(self):
        self.write_log(log(PASSING, end=None))
        evidence = self.export()
        self.assertEqual(evidence["result"], "incomplete")

    def test_a_test_started_without_a_result_is_incomplete(self):
        self.write_log(log(PASSING, end="failed", started_only=["testThree"]))
        evidence = self.export()
        self.assertEqual(evidence["result"], "incomplete")
        self.assertIn("AppUITests.testThree", evidence["result_reasons"][0])

    def test_no_tests_is_incomplete(self):
        self.bundle_tests = []
        self.write_log(log([]))
        self.assertEqual(self.export()["result"], "incomplete")

    def test_log_and_bundle_disagreeing_is_contradictory(self):
        self.bundle_tests = [("testOne", "passed"), ("testTwo", "failed")]
        evidence = self.export()
        self.assertEqual(evidence["result"], "contradictory")
        self.assertIn("disagree", evidence["result_reasons"][0])

    def test_a_test_only_one_source_knows_is_contradictory(self):
        self.bundle_tests = [("testOne", "passed")]
        self.assertEqual(self.export()["result"], "contradictory")

    def test_a_log_ending_both_ways_is_contradictory(self):
        self.write_log(log(PASSING, end="both"))
        self.assertEqual(self.export()["result"], "contradictory")

    def test_a_failure_outside_the_tests_is_failed(self):
        self.write_log(log(PASSING, end="failed"))
        evidence = self.export()
        self.assertEqual(evidence["result"], "failed")
        self.assertIn("outside the tests", evidence["result_reasons"][0])

    # -- missing and malformed inputs -------------------------------------------------------------------
    def test_missing_inputs(self):
        for name, text in [("run.json", "missing the runner's record"), ("device.json", "missing the runner's device record"),
                           ("xcodebuild.log", "missing xcodebuild.log")]:
            with self.subTest(name):
                saved = (self.run_dir / name).read_bytes()
                (self.run_dir / name).unlink()
                self.assertFails(text)
                (self.run_dir / name).write_bytes(saved)
        shutil.rmtree(self.run_dir / "ui-tests.xcresult")
        self.assertFails("missing the result bundle ui-tests.xcresult")

    def test_malformed_inputs(self):
        (self.run_dir / "run.json").write_text("{not json")
        self.assertFails("is not JSON")
        self.write_run({"schema": 2})
        self.assertFails("schema 2")

    def test_no_xcresulttool(self):
        self.patch("xcresulttool", lambda *a: None)
        self.assertFails("could not be read (xcresulttool)")

    def test_a_malformed_bundle_answer(self):
        self.patch("xcresulttool", lambda *a: "[1, 2")
        self.assertFails("malformed")

    def test_an_output_that_is_not_empty(self):
        self.out.mkdir()
        (self.out / "x").write_text("x")
        self.assertFails("is not empty")

    # -- screenshots that do not match ------------------------------------------------------------------
    def test_a_file_on_disk_that_matches_no_capture(self):
        (self.run_dir / "screenshots" / "01-start.png").write_bytes(png(4, 8, b"tampered"))
        self.assertFails("matches none of the result bundle's captures")

    def test_a_file_on_disk_no_test_attached(self):
        (self.run_dir / "screenshots" / "99-stray.png").write_bytes(png(2, 2))
        self.assertFails("no test attached: 99-stray")

    def test_an_attachment_that_is_not_a_png(self):
        self.attached[0] = ("testOne", "01-start", 1.0, b"not a png")
        shutil.rmtree(self.run_dir / "screenshots")
        self.assertFails("not a PNG")

    # -- source identity --------------------------------------------------------------------------------
    def test_the_recorded_revision_is_the_tested_revision(self):
        source = self.export()["source"]
        self.assertEqual((source["revision"], source["recorded_by"]), (SHA, "git"))

    def test_a_different_given_revision_is_refused(self):
        self.assertFails(f"is not the revision the run recorded ({SHA})", source_revision=OTHER)

    def test_the_same_given_revision_is_accepted(self):
        self.assertEqual(self.export(source_revision=SHA)["source"]["revision"], SHA)

    def test_no_recorded_revision_needs_an_explicit_one(self):
        run = json.loads((self.run_dir / "run.json").read_text())
        run["source"] = {"revision": None}
        self.write_run(run)
        self.assertFails("pass --source-revision")
        source = self.export(source_revision=OTHER)["source"]
        self.assertEqual((source["revision"], source["recorded_by"]), (OTHER, "export-evidence --source-revision"))

    def test_a_short_or_malformed_revision_is_refused(self):
        self.assertFails("full 40-character", source_revision="0123456")
        run = json.loads((self.run_dir / "run.json").read_text())
        run["source"]["revision"] = "HEAD"
        self.write_run(run)
        self.assertFails("is not a full commit SHA")

    # -- names ------------------------------------------------------------------------------------------
    def test_configurable_names(self):
        (self.run_dir / "ui-tests.xcresult").rename(self.run_dir / "journey.xcresult")
        (self.run_dir / "journey.mp4").write_bytes(mp4(1206, 2622, 3.0, 64))
        (self.run_dir / "screenshots").rename(self.run_dir / "shots")
        evidence = self.export(name="journey", screenshots="shots", video_out="videos/wallet-journey.mp4")
        self.assertEqual(evidence["run"]["name"], "journey")
        self.assertEqual(evidence["video"]["path"], "videos/wallet-journey.mp4")
        self.assertTrue((self.out / "videos" / "wallet-journey.mp4").is_file())
        self.assertIn("journey.xcresult", evidence["artifacts_sha256"])
        self.assertEqual(len(evidence["screenshots"]), 2)

    def test_the_run_name_comes_from_run_json(self):
        run = json.loads((self.run_dir / "run.json").read_text())
        run["name"] = "journey"
        self.write_run(run)
        (self.run_dir / "ui-tests.xcresult").rename(self.run_dir / "journey.xcresult")
        self.assertEqual(self.export()["run"]["name"], "journey")

    def test_app_metadata_is_recorded_and_hashed(self):
        meta = self.base / "app.json"
        meta.write_text(json.dumps({"network": "regtest", "app": "Example"}))
        evidence = self.export(app_metadata=meta)
        self.assertEqual(evidence["app"], {"network": "regtest", "app": "Example"})
        self.assertEqual(evidence["artifacts_sha256"]["app_metadata"], hashlib.sha256(meta.read_bytes()).hexdigest())

    # -- the device -------------------------------------------------------------------------------------
    def test_device_from_both_records(self):
        device = self.export()["device"]
        self.assertEqual(device["name"], "iPhone 17 Pro")
        self.assertEqual(device["platform"], "iOS Simulator")
        self.assertEqual(device["runtime"], "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        self.assertEqual(device["os_version"], "27.0")

    def test_device_mismatch_is_refused(self):
        self.bundle_device["modelName"] = "iPhone Duo"
        self.assertFails("chose iPhone 17 Pro but the tests ran on iPhone Duo")

    def mac_catalyst_run(self):
        # as ui-tests records the Mac: no name (the bundle's is used), the model and the host's OS
        (self.run_dir / "device.json").write_text(json.dumps({
            "platform": "Mac Catalyst", "type": "Mac", "model": "VirtualMac2,1", "os": "macOS 26.4 (25E246)", "architecture": "arm64"}))
        self.bundle_device = {"modelName": "My Mac", "osVersion": "26.4", "platform": "macOS", "architecture": "arm64"}
        run = json.loads((self.run_dir / "run.json").read_text())
        run["platform"] = "Mac Catalyst"
        self.write_run(run)

    def test_a_mac_catalyst_run(self):
        self.mac_catalyst_run()
        evidence = self.export()
        self.assertEqual((evidence["run"]["platform"], evidence["device"]["platform"]), ("Mac Catalyst", "macOS"))
        self.assertEqual({k: evidence["device"][k] for k in ("name", "model", "os", "os_version", "architecture")},
                         {"name": "My Mac", "model": "VirtualMac2,1", "os": "macOS 26.4 (25E246)", "os_version": "26.4",
                          "architecture": "arm64"})

    def test_a_catalyst_run_is_never_a_simulator_run(self):
        self.mac_catalyst_run()
        self.bundle_device = {"modelName": "iPhone 17 Pro", "osVersion": "27.0", "platform": "iOS Simulator", "architecture": "arm64"}
        self.assertFails("run.json records the tests as run on Mac Catalyst but the result bundle names iOS Simulator")

    def test_a_simulator_run_is_never_a_catalyst_run(self):
        self.bundle_device = {"modelName": "iPhone 17 Pro", "osVersion": "26.4", "platform": "macOS", "architecture": "arm64"}
        self.assertFails("run.json records the tests as run on iOS Simulator but the result bundle names macOS")

    # -- the recording ----------------------------------------------------------------------------------
    def test_no_recording(self):
        evidence = self.export()
        self.assertIsNone(evidence["video"])
        self.assertIn("no screen recording (ui-tests.mp4)", evidence["video_omitted"])

    def test_copied_without_a_transcoder(self):
        data = mp4(1206, 2622, 3.0, 64)
        (self.run_dir / "ui-tests.mp4").write_bytes(data)
        evidence = self.export()
        self.assertFalse(evidence["video"]["transcoded"])
        self.assertEqual(evidence["video"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(evidence["original_video"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual((evidence["video"]["width"], evidence["video"]["duration_seconds"]), (1206, 3.0))

    def test_too_large_without_a_transcoder(self):
        (self.run_dir / "ui-tests.mp4").write_bytes(mp4(1206, 2622, 3.0, 4096))
        evidence = self.export(max_video_bytes=1024)
        self.assertIsNone(evidence["video"])
        self.assertIn("no ffmpeg", evidence["video_omitted"])
        self.assertIsNotNone(evidence["original_video"])

    def test_transcode_required_but_absent(self):
        (self.run_dir / "ui-tests.mp4").write_bytes(mp4(1206, 2622, 3.0, 64))
        evidence = self.export(transcode="ffmpeg")
        self.assertIsNone(evidence["video"])
        self.assertIn("--transcode ffmpeg, but ffmpeg or ffprobe is not installed", evidence["video_omitted"])

    def test_transcode_none_copies_even_with_ffmpeg(self):
        (self.run_dir / "ui-tests.mp4").write_bytes(mp4(1206, 2622, 3.0, 64))
        self.patch_obj(ev.shutil, "which", lambda name: "/usr/bin/" + name)
        self.patch("probe", lambda path: {"width": 1206, "height": 2622, "duration_seconds": 3.0,
                                          "bytes": Path(path).stat().st_size, "sha256": ev.digest(path)})
        evidence = self.export(transcode="none")
        self.assertFalse(evidence["video"]["transcoded"])

    def test_a_failing_transcoder_is_recorded(self):
        (self.run_dir / "ui-tests.mp4").write_bytes(mp4(1206, 2622, 3.0, 64))
        self.patch_obj(ev.shutil, "which", lambda name: "/usr/bin/" + name)
        self.patch("probe", lambda path: {"width": 1206, "height": 2622, "duration_seconds": 3.0,
                                          "bytes": Path(path).stat().st_size, "sha256": ev.digest(path)})

        def broken(source, destination, original, max_bytes):
            raise subprocess.CalledProcessError(1, ["ffmpeg"])
        self.patch("transcode", broken)
        evidence = self.export()
        self.assertIsNone(evidence["video"])
        self.assertIn("transcoding failed", evidence["video_omitted"])
        self.assertFalse((self.out / "video" / "ui-tests.mp4").exists())

    def test_an_unreadable_recording(self):
        (self.run_dir / "ui-tests.mp4").write_bytes(b"not an mp4")
        evidence = self.export()
        self.assertIsNone(evidence["video"])
        self.assertIn("unreadable", evidence["video_omitted"])

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
    def test_a_real_transcode(self):
        source = self.base / "source.mp4"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=1206x2622:d=2",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", str(source)], check=True)
        shutil.copyfile(source, self.run_dir / "ui-tests.mp4")
        self.tools = {"ffmpeg", "ffprobe"}
        evidence = self.export()
        self.assertTrue(evidence["video"]["transcoded"])
        self.assertEqual(evidence["video"]["width"], 720)
        self.assertNotEqual(evidence["video"]["sha256"], evidence["original_video"]["sha256"])


if __name__ == "__main__":
    unittest.main()
