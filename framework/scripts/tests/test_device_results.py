"""Unit tests for framework/native/ci/device-results, which grades a device run of native-demo from its console.

The console lines are an iPhone 17 Pro Max's (iOS 27.2), as native-demo printed them on 2026-11-08.
"""
import importlib.machinery
import importlib.util
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "native" / "ci" / "device-results"
loader = importlib.machinery.SourceFileLoader("device_results", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
dr = importlib.util.module_from_spec(spec)
loader.exec_module(dr)

ID = "art.fralex.leannative.nativedemo."
SELFTEST = """selftest: TCP echo: echo: selftest
selftest: background run: completed, work started, success true
selftest: background run past its deadline: expired, work started, success false
selftest: effect scope: started, drained true, late result delivered false, now 0 tasks
selftest: typed keychain.add: ok added
selftest: typed keychain.add again: ok alreadyExists
selftest: typed keychain.get: ok 010203
selftest: typed keychain.delete: ok
selftest: typed keychain.get after delete: ok none
selftest: Refresh status: {"status":"available"}
selftest: Schedule refresh: {"ok":true}
selftest: Schedule processing: {"ok":true}
selftest: Schedule unlisted id: {"detail":"not registered: list it in BGTaskSchedulerPermittedIdentifiers","error":"notPermitted","ok":false}
selftest: Keychain sync set: {"ok":true,"status":0}
selftest: Keychain sync get: {"hex":"00ff10","status":0}
selftest: Keychain local get: {"hex":null,"status":-25300}
selftest: Keychain sync delete: {"ok":true,"status":0}
selftest: done""".splitlines()
TASKS = [f"bgtask launched: {ID}refresh (refresh)", f"background run {ID}refresh: completed, work started, success true",
         f"bgtask launched: {ID}processing (processing)", f"bgtask expired: {ID}processing",
         f"background run {ID}processing: expired, work started, success false"]
HAND = ["auth: asking (8 s after launch, NATIVEDEMO_AUTH_AFTER)", "auth: authenticated",
        "ble: BLE state: ok poweredOn", "ble: BLE connect: failed busy",
        "ble: BLE connected: id 5FDF35E5-78D9-B556-5CAE-2CAF335E2DC1, name 69E6, service 13D63400-2C97-0004-0000-4C6564676572, 3 characteristics",
        "ble: BLE closed: ok "]


def results(lines):
    return {r["check"]: r["result"] for r in dr.grade(lines)}


class Grade(unittest.TestCase):
    def test_a_whole_run_passes_every_check(self):
        self.assertEqual(set(results(SELFTEST + TASKS + HAND).values()), {"passed"})

    def test_a_check_whose_line_never_came_is_not_reached(self):
        r = results(SELFTEST + HAND)
        self.assertEqual(r["bgtask-launch"], "not reached")
        self.assertEqual(r["bgtask-expiration"], "not reached")
        self.assertEqual(r["face-id"], "passed")

    def test_another_answer_fails_and_is_quoted(self):
        lines = [l.replace('{"ok":true}', '{"error":"unavailable","ok":false}') for l in SELFTEST]
        r = {x["check"]: x for x in dr.grade(lines)}
        self.assertEqual(r["bgtask-schedule"]["result"], "failed")
        self.assertIn('selftest: Schedule refresh: {"error":"unavailable","ok":false}', r["bgtask-schedule"]["lines"])

    def test_face_id_cancelled_fails_and_the_question_is_not_an_answer(self):
        self.assertEqual(results(["auth: asking (8 s after launch, NATIVEDEMO_AUTH_AFTER)"])["face-id"], "not reached")
        self.assertEqual(results(["auth: not authenticated: cancelled (userCancel)"])["face-id"], "failed")

    def test_a_busy_answer_beside_a_connection_still_passes(self):
        self.assertEqual(results(HAND)["ble-connect"], "passed")
        self.assertEqual(results(["ble: BLE connect: timeout"])["ble-connect"], "failed")

    def test_a_run_expired_before_its_work_started_still_shows_expiry(self):
        lines = TASKS[:3] + [f"bgtask expired: {ID}processing",
                             f"background run {ID}processing: expired, work never started, success false"]
        self.assertEqual(results(lines)["bgtask-expiration"], "failed")

    def test_the_manifest_counts_each_result(self):
        with tempfile.TemporaryDirectory() as d:
            console, out = Path(d, "console.log"), Path(d, "results.json")
            console.write_text("\n".join(["Launched application with art.fralex.leannative.nativedemo bundle identifier."]
                                         + SELFTEST + HAND) + "\n")
            with redirect_stdout(io.StringIO()) as table:
                self.assertEqual(dr.main([str(console), "--out", str(out)]), 0)
            m = json.loads(out.read_text())
            self.assertEqual(m["schema"], "leannative.device-results/1")
            self.assertEqual(m["counts"], {"passed": 10, "failed": 0, "not reached": 2})
            self.assertIn("not reached  bgtask-launch", table.getvalue())


if __name__ == "__main__":
    unittest.main()
