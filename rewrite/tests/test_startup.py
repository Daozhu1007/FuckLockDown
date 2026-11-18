"""Exercise production startup conditions against a self-built native window host.

The fixture owns a six-byte native return function and no browser code. It waits
for that function's return value to change before executing it. The launchers use
the same source and compilation conditions as production, with only a harmless
target plan and an asInvoker manifest substituted.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import time
import unittest
import uuid

from build_support import load_verified_build


class StartupIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build, artifacts = load_verified_build()
        cls.fixture = Path(cls.build["fixture"])
        cls.launcher = Path(cls.build["fixture_startup_launcher"])
        cls.timeout_launcher = Path(cls.build["fixture_timeout_launcher"])
        cls.visible_launcher = Path(cls.build["fixture_visible_launcher"])
        cls.run_root = artifacts / ("startup-run-" + uuid.uuid4().hex)
        cls.run_root.mkdir()

    def fixture_args(self, result, value=1, extra=()):
        return ["--native-rva", self.build["fixture_rva"], "--expected-return", str(value),
                "--result", str(result), *extra]

    def events(self, log):
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def launch(self, name, extra=(), launcher=None):
        result, log = self.run_root / (name + ".json"), self.run_root / (name + ".jsonl")
        command = [str(launcher or self.launcher), "--exe", str(self.fixture), "--no-ui", "--log", str(log),
                   "--", *self.fixture_args(result, extra=extra)]
        run = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace", timeout=20,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        return run, result, self.events(log)

    def assert_cleaned_child(self, events):
        created = next(item["data"] for item in events if item["eventType"] == "child_created_suspended")
        cleaned = next(item["data"] for item in events if item["eventType"] == "failed_child_cleanup")
        self.assertEqual(cleaned["pid"], created["pid"])
        self.assertEqual(cleaned["wait"], 0, "The failed child must be confirmed terminated")
        self.assertEqual(events[-1]["eventType"], "error")

    def test_startup_window_leads_to_verified_patch_and_native_execution(self):
        before = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        run, result, events = self.launch("startup-success", extra=[
            "--ready-window", self.build["fixture_startup_class"], "--wait-for-patch-ms", "10000"])
        self.assertEqual(run.returncode, 0, json.dumps(events, ensure_ascii=False))
        recorded = json.loads(result.read_text(encoding="utf-8"))
        self.assertEqual(recorded["value"], 1)
        self.assertTrue(recorded["readinessWindowCreated"])
        self.assertEqual(hashlib.sha256(self.fixture.read_bytes()).hexdigest(), before)
        kinds = [item["eventType"] for item in events]
        required = ["child_initializing", "startup_ready", "child_suspended_for_policy", "patch_verified", "child_resumed"]
        self.assertEqual([kind for kind in kinds if kind in required], required)
        self.assertEqual(events[-1]["eventType"], "child_exit")
        self.assertEqual(events[-1]["data"]["code"], 0)

    def test_child_exiting_before_readiness_is_detected_without_patch(self):
        run, result, events = self.launch("exited-before-ready", extra=["--exit-before-ready"])
        self.assertEqual(run.returncode, 1)
        self.assertFalse(result.exists())
        self.assertNotIn("patch_verified", [item["eventType"] for item in events])
        self.assertIn("exit 93", events[-1]["data"]["message"])
        self.assert_cleaned_child(events)

    def test_visible_policy_waits_for_hidden_window_to_be_shown_before_patching(self):
        run, result, events = self.launch("delayed-visible-window", extra=[
            "--ready-window", self.build["fixture_startup_class"], "--show-after-ms", "400",
            "--wait-for-patch-ms", "10000"], launcher=self.visible_launcher)
        self.assertEqual(run.returncode, 0, json.dumps(events, ensure_ascii=False))
        recorded = json.loads(result.read_text(encoding="utf-8"))
        self.assertEqual(recorded["valueBeforeShowing"], 2,
                         "The matching hidden window must not activate the policy")
        self.assertTrue(recorded["readinessWindowVisible"])
        self.assertEqual(recorded["value"], 1)
        ready = next(item["data"] for item in events if item["eventType"] == "startup_ready")
        self.assertTrue(ready["requireVisible"])

    def test_visible_policy_rejects_matching_window_that_remains_hidden(self):
        run, result, events = self.launch("never-visible-window", extra=[
            "--ready-window", self.build["fixture_startup_class"], "--wait-for-patch-ms", "10000"],
            launcher=self.visible_launcher)
        self.assertEqual(run.returncode, 1)
        self.assertFalse(result.exists())
        kinds = [item["eventType"] for item in events]
        self.assertNotIn("startup_ready", kinds)
        self.assertNotIn("patch_verified", kinds)
        self.assertIn("TimeoutException", events[-1]["data"]["message"])
        self.assert_cleaned_child(events)

    def test_changed_remote_bytes_after_resume_abort_and_clean_child(self):
        before = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        run, result, events = self.launch("changed-after-resume", extra=[
            "--change-before-ready", "--ready-window", self.build["fixture_startup_class"],
            "--wait-for-patch-ms", "10000"])
        self.assertEqual(run.returncode, 1)
        self.assertFalse(result.exists())
        kinds = [item["eventType"] for item in events]
        self.assertIn("child_suspended_for_policy", kinds)
        self.assertNotIn("patch_verified", kinds)
        self.assertIn("Remote bytes do not match", events[-1]["data"]["message"])
        self.assertEqual(hashlib.sha256(self.fixture.read_bytes()).hexdigest(), before)
        self.assert_cleaned_child(events)

    def test_timeout_ignores_same_class_window_in_other_process_and_preserves_it(self):
        sentinel_result, signal = self.run_root / "sentinel.json", self.run_root / "sentinel-ready.txt"
        sentinel = subprocess.Popen([str(self.fixture), *self.fixture_args(sentinel_result, value=2, extra=[
            "--ready-window", self.build["fixture_startup_class"], "--ready-signal", str(signal),
            "--hold-ms", "10000"])], creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            deadline = time.monotonic() + 5
            while not signal.exists() and time.monotonic() < deadline:
                if sentinel.poll() is not None:
                    self.fail("The independent harmless window fixture exited before readiness")
                time.sleep(0.01)
            self.assertTrue(signal.exists(), "The independent readiness window was not created")
            self.assertEqual(int(signal.read_text()), sentinel.pid)
            started = time.monotonic()
            run, result, events = self.launch("startup-timeout", extra=["--wait-for-patch-ms", "10000"],
                                               launcher=self.timeout_launcher)
            self.assertEqual(run.returncode, 1)
            self.assertLess(time.monotonic() - started, 5)
            self.assertFalse(result.exists())
            self.assertNotIn("startup_ready", [item["eventType"] for item in events])
            self.assertIn("TimeoutException", events[-1]["data"]["message"])
            self.assert_cleaned_child(events)
            self.assertIsNone(sentinel.poll(), "Failed startup must not terminate another process")
        finally:
            # Only this test-created process handle is terminated, never an enumerated PID.
            if sentinel.poll() is None:
                sentinel.terminate()
            sentinel.wait(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
