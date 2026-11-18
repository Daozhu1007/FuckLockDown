"""Load the exact build under test and reject stale inputs or output files."""

import importlib.util
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_verified_build():
    path = Path(os.environ.get("NPG_TEST_BUILD_MANIFEST", ROOT / "test-artifacts/build.json")).resolve()
    manifest = json.loads(path.read_text(encoding="utf-8"))
    specification = importlib.util.spec_from_file_location("npg_build_tools", ROOT / "build.py")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    module.validate_manifest(manifest)
    return manifest, path.parent
