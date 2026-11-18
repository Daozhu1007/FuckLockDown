"""Integration checks using only the self-built, harmless fixture executable."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid

from build_support import load_verified_build


ROOT = Path(__file__).resolve().parents[1]


class LauncherIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build, artifacts = load_verified_build()
        cls.fixture = Path(cls.build["fixture"])
        cls.launcher = Path(cls.build["fixture_launcher"])
        cls.run_root = artifacts / ("run-" + uuid.uuid4().hex)
        cls.run_root.mkdir()

    def run_command(self, args):
        return subprocess.run([str(x) for x in args], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=30,
                              creationflags=subprocess.CREATE_NO_WINDOW)

    def fixture_args(self, result, value, forwarded=()):
        return ["--native-rva", self.build["fixture_rva"], "--expected-return", str(value),
                "--result", str(result), "--", *forwarded]

    def events(self, log):
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def test_baseline_fixture_calls_unmodified_native_code(self):
        result = self.run_root / "baseline.json"
        run = self.run_command([self.fixture, *self.fixture_args(result, 2)])
        self.assertEqual(run.returncode, 0, run.stderr)
        recorded = json.loads(result.read_text(encoding="utf-8"))
        self.assertEqual(recorded["value"], 2)
        self.assertEqual(recorded["markerText"], "NPG_NATIVE_FIXTURE_20261116")

    def test_actual_remote_patch_preserves_disk_image_and_arguments(self):
        result, log = self.run_root / "patched.json", self.run_root / "patched.jsonl"
        forwarded = ["two words", "", 'literal"quote', "trailing\\", "path with spaces\\", "$(literal)"]
        before = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        run = self.run_command([self.launcher, "--exe", self.fixture, "--no-ui", "--log", log, "--",
                                *self.fixture_args(result, 1, forwarded)])
        self.assertEqual(run.returncode, 0, log.read_text(encoding="utf-8") if log.exists() else run.stderr)
        data = json.loads(result.read_text(encoding="utf-8"))
        self.assertEqual(data["value"], 1)
        self.assertEqual(data["arguments"], forwarded)
        self.assertEqual(data["markerText"], "NQG_NATIVE_FIXTURE_20261116",
                         "The data neutre must corrupt the marker in the child's memory")
        self.assertEqual(hashlib.sha256(self.fixture.read_bytes()).hexdigest(), before)
        kinds = [x["eventType"] for x in self.events(log)]
        self.assertEqual(kinds, ["preflight", "child_created_suspended", "image_data_neutralized",
                                 "patch_verified", "child_resumed", "child_exit"])
        neutre = next(x for x in self.events(log) if x["eventType"] == "image_data_neutralized")["data"]
        self.assertEqual(neutre["applied"], 1)
        self.assertFalse(neutre["executableMemoryChanged"])

    def test_check_mode_never_creates_a_child(self):
        result, log = self.run_root / "check-result.json", self.run_root / "check.jsonl"
        run = self.run_command([self.launcher, "--exe", self.fixture, "--check", "--no-ui", "--log", log,
                                "--", *self.fixture_args(result, 1)])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(result.exists())
        self.assertEqual([x["eventType"] for x in self.events(log)], ["preflight"])
        reported = json.loads(run.stdout.strip().splitlines()[-1])
        self.assertTrue(reported["verified"])
        self.assertEqual(reported["neutreCount"], 1)

    def test_failure_after_creation_cleans_only_its_suspended_child(self):
        result, log = self.run_root / "failed-child-result.json", self.run_root / "failed-child.jsonl"
        run = self.run_command([self.launcher, "--exe", self.fixture, "--no-ui", "--log", log,
                                "--test-fail-after-create", "--", *self.fixture_args(result, 1)])
        self.assertEqual(run.returncode, 1)
        self.assertFalse(result.exists())
        events = self.events(log)
        self.assertEqual([item["eventType"] for item in events],
                         ["preflight", "child_created_suspended", "image_data_neutralized",
                          "failed_child_cleanup", "error"])
        created = next(item for item in events if item["eventType"] == "child_created_suspended")["data"]
        cleanup = next(item for item in events if item["eventType"] == "failed_child_cleanup")["data"]
        self.assertTrue(cleanup["stopped"])
        self.assertEqual(cleanup["wait"], 0)
        self.assertEqual(cleanup["pid"], created["pid"])

    def test_changed_file_is_rejected_before_process_creation(self):
        folder = self.run_root / "wrong identity"
        folder.mkdir()
        altered = folder / self.fixture.name
        shutil.copyfile(self.fixture, altered)
        raw = bytearray(altered.read_bytes())
        raw[0x50] ^= 1
        altered.write_bytes(raw)
        result, log = self.run_root / "changed-result.json", self.run_root / "changed.jsonl"
        run = self.run_command([self.launcher, "--exe", altered, "--no-ui", "--log", log,
                                "--", *self.fixture_args(result, 1)])
        self.assertEqual(run.returncode, 1)
        self.assertFalse(result.exists())
        events = self.events(log)
        self.assertEqual([x["eventType"] for x in events], ["error"])
        self.assertIn("SHA-256", events[0]["data"]["message"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
