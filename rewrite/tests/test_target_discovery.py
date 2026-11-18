"""Selection and compatibility diagnostics; fixtures are compiled, never executed."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CSC = Path(os.environ.get("SystemRoot", "C:/Windows")) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"


@unittest.skipUnless(os.name == "nt" and CSC.is_file(), "Requires the Windows .NET Framework compiler")
class TargetDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="npg-discovery-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.harness = cls.directory / "DiscoveryHarness.exe"
        cls.compile([ROOT / "src/TargetDiscovery.cs", ROOT / "tests/DiscoveryHarness.cs"], cls.harness)
        cls.old = cls.make_fixture("old installation", "2.1.3.8", "x86")
        cls.supported = cls.make_fixture("supported installation", "2.1.6.3", "x64")
        cls.expected_hash = hashlib.sha256(cls.supported.read_bytes()).hexdigest()

    @classmethod
    def compile(cls, sources, output, architecture="x64"):
        run = subprocess.run(
            [str(CSC), "/nologo", "/utf8output", "/target:exe", "/platform:" + architecture,
             "/out:" + str(output), *map(str, sources)],
            capture_output=True, encoding="utf-8", errors="replace", timeout=30,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        if run.returncode:
            raise AssertionError(run.stdout + run.stderr)

    @classmethod
    def make_fixture(cls, folder, version, architecture):
        directory = cls.directory / folder
        directory.mkdir()
        source = directory / "Fixture.cs"
        source.write_text(
            'using System.Reflection; [assembly: AssemblyFileVersion("' + version + '")] '
            'internal static class Fixture { private static int Main() { return 0; } }',
            encoding="utf-8",
        )
        output = directory / "LockDownBrowser.exe"
        cls.compile([source], output, architecture)
        return output

    def resolve(self, candidates=(), explicit=None):
        return subprocess.run(
            [str(self.harness), "LockDownBrowser.exe", self.expected_hash,
             str(explicit) if explicit is not None else "-", *map(str, candidates)],
            capture_output=True, encoding="utf-8", errors="replace", timeout=15,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

    def test_supported_hash_wins_over_first_installed_version(self):
        run = self.resolve([self.old, self.supported])
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertEqual(Path(run.stdout.strip()), self.supported)

    def test_explicit_selection_does_not_fall_back_to_different_installation(self):
        run = self.resolve([self.supported], explicit=self.old)
        self.assertEqual(run.returncode, 3)
        self.assertIn("SHA-256", run.stdout)
        self.assertIn(str(self.old), run.stdout)
        self.assertIn("2.1.3.8", run.stdout)
        self.assertIn("x86 (32-bit)", run.stdout)

    def test_unsupported_installation_reports_version_architecture_and_expected_hash(self):
        run = self.resolve([self.old])
        self.assertEqual(run.returncode, 3)
        self.assertIn("InvalidDataException", run.stdout)
        self.assertIn("2.1.3.8", run.stdout)
        self.assertIn("x86 (32-bit)", run.stdout)
        self.assertIn(self.expected_hash, run.stdout)
        self.assertIn("--exe", run.stdout)

    def test_missing_installation_has_actionable_file_error(self):
        missing = self.directory / "not installed" / "LockDownBrowser.exe"
        run = self.resolve([missing])
        self.assertEqual(run.returncode, 3)
        self.assertIn("FileNotFoundException", run.stdout)
        self.assertNotIn("DirectoryNotFoundException", run.stdout)
        self.assertIn(str(missing), run.stdout)
        self.assertIn("--exe", run.stdout)

    def test_explicit_missing_path_does_not_silently_select_other_candidate(self):
        missing = self.directory / "not installed" / "LockDownBrowser.exe"
        run = self.resolve([self.supported], explicit=missing)
        self.assertEqual(run.returncode, 3)
        self.assertIn("FileNotFoundException", run.stdout)
        self.assertIn(str(missing), run.stdout)

    def test_matching_bytes_under_wrong_explicit_filename_are_rejected(self):
        renamed = self.directory / "RenamedBrowser.exe"
        shutil.copyfile(self.supported, renamed)
        run = self.resolve(explicit=renamed)
        self.assertEqual(run.returncode, 3)
        self.assertIn("Unexpected target filename", run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
