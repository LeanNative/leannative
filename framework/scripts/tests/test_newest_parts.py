"""Unit tests for framework/native/ci/newest-parts, the parts' directories ios-app.yml's media job joins.

The downloaded directory is as actions/download-artifact leaves it: after "Re-run failed jobs" a run's listing
holds every attempt's artifacts (winnow-lean run 42046318318: part 1 again under attempt 2, part 0 only under
attempt 1).
"""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "native" / "ci" / "newest-parts"
loader = importlib.machinery.SourceFileLoader("newest_parts", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
np = importlib.util.module_from_spec(spec)
loader.exec_module(np)

RUN = "42046318318"
UI = "journey"


class NewestPartsTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.downloaded = Path(scratch.name)

    def artifact(self, attempt, part, ui=UI):
        directory = self.downloaded / f"app-{RUN}-{attempt}-part-{part}"
        (directory / ui).mkdir(parents=True)
        return directory / ui

    def parts(self, count):
        return np.newest_parts(self.downloaded, count, UI)

    def test_a_full_run_is_its_parts_in_order(self):
        wanted = [self.artifact(1, part) for part in range(3)]
        self.assertEqual(self.parts(3), wanted)

    def test_a_rerun_of_failed_jobs_keeps_the_part_that_passed(self):
        first = self.artifact(1, 0)
        self.artifact(1, 1)
        rerun = self.artifact(2, 1)
        self.assertEqual(self.parts(2), [first, rerun])

    def test_attempts_are_numbers(self):
        self.artifact(9, 0)
        tenth = self.artifact(10, 0)
        self.assertEqual(self.parts(1), [tenth])

    def test_parts_are_in_order_past_nine(self):
        wanted = [self.artifact(1, part) for part in range(11)]
        self.assertEqual(self.parts(11), wanted)

    def test_a_part_missing_from_every_attempt_fails(self):
        self.artifact(1, 1)
        self.artifact(2, 1)
        with self.assertRaises(SystemExit) as failure:
            self.parts(2)
        self.assertEqual(failure.exception.code, "::error::part 0's evidence has no journey directory")

    def test_the_newest_attempt_without_the_directory_fails(self):
        self.artifact(1, 0)
        self.artifact(2, 0, ui="other")
        with self.assertRaises(SystemExit) as failure:
            self.parts(1)
        self.assertEqual(failure.exception.code, "::error::part 0's evidence has no journey directory")

    def test_other_names_are_not_parts(self):
        (self.downloaded / f"app-{RUN}-1" / UI).mkdir(parents=True)
        (self.downloaded / f"lean-{RUN}-1-part-0" / UI).mkdir(parents=True)
        (self.downloaded / f"app-{RUN}-2-part-0").write_text("a file")
        with self.assertRaises(SystemExit):
            self.parts(1)

    def test_the_command_prints_one_line_and_annotates_a_failure(self):
        first, second = self.artifact(1, 0), self.artifact(2, 1)
        command = [sys.executable, "-I", str(SCRIPT), str(self.downloaded)]
        done = subprocess.run(command + [json.dumps(["a b", "c"]), UI], capture_output=True, text=True, check=True)
        self.assertEqual(done.stdout, f"{first} {second}\n")
        failed = subprocess.run(command + [json.dumps(["a", "b", "c"]), UI], capture_output=True, text=True)
        self.assertEqual((failed.returncode, failed.stdout), (1, ""))
        self.assertIn("::error::part 2's evidence has no journey directory", failed.stderr)

    def test_the_command_says_how_to_call_it(self):
        with self.assertRaises(SystemExit) as failure:
            np.main([])
        self.assertIn("newest-parts <downloaded>", failure.exception.code)


if __name__ == "__main__":
    unittest.main()
