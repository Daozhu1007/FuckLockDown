"""Build the version-pinned launcher and a harmless native-code test fixture.

Uses the .NET Framework compiler already shipped on this Windows host. It does
not execute, install, patch on disk, or register the original browser.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pefile


ROOT = Path(__file__).resolve().parent
CSC = Path(os.environ.get("SystemRoot", "C:/Windows")) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
STARTUP_FIXTURE_CLASS = "NPG_NATIVE_FIXTURE_READY_20261117"


def file_identity(path):
    path = Path(path).resolve()
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}


def validate_manifest(manifest):
    """Reject stale sources, embedded resources, compiler, flags, and output files."""
    if manifest.get("schema_version") != 2:
        raise ValueError("Rebuild: a complete schema-2 build manifest is required")
    records = [manifest["compiler_identity"], *manifest["input_files"], *manifest["artifact_files"]]
    for compilation in manifest["compilations"]:
        records.extend(compilation["sources"])
        records.extend(resource["file"] for resource in compilation["resources"])
        records.extend([compilation["manifest"], compilation["output"]])
    for recorded in records:
        path = Path(recorded["path"])
        if not path.is_file() or file_identity(path) != recorded:
            raise ValueError("Rebuild: build input or artifact changed: " + str(path))
    production = next((item for item in manifest["compilations"]
                       if item["output"]["path"] == manifest["production_launcher"]), None)
    startup = next((item for item in manifest["compilations"]
                    if item["output"]["path"] == manifest["fixture_startup_launcher"]), None)
    if production is None or startup is None:
        raise ValueError("Missing production or startup-fixture compilation record")
    if production["flags"]["test_hooks"] or startup["flags"]["test_hooks"]:
        raise ValueError("Production and startup-fixture launchers must exclude test hooks")
    for flag in ("architecture", "check_only", "console", "test_hooks"):
        if production["flags"][flag] != startup["flags"][flag]:
            raise ValueError("Startup fixture diverges from the production compilation flag: " + flag)


def compile_cs(sources, destination, resources=(), test_hooks=False, admin=False, check_only=False, console=False):
    if not isinstance(sources, (list, tuple)):
        sources = [sources]
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest = ROOT / ("src/browser.manifest" if admin else "src/app.manifest")
    source_identities = [file_identity(source) for source in sources]
    resource_identities = [{"name": name, "file": file_identity(path)} for path, name in resources]
    manifest_identity = file_identity(manifest)
    command = [str(CSC), "/nologo", "/optimize+", "/platform:x64", "/target:" + ("exe" if console else "winexe"),
               "/utf8output", "/r:System.Web.Extensions.dll", "/r:System.Windows.Forms.dll",
               "/win32manifest:" + str(manifest), "/out:" + str(destination)]
    command.extend("/resource:" + str(path) + "," + name for path, name in resources)
    if test_hooks:
        command.append("/define:NPG_TEST_HOOKS")
    if check_only:
        command.append("/define:CHECK_ONLY")
    command.extend(str(source) for source in sources)
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise RuntimeError("Compiler failed:\n" + result.stdout + result.stderr)
    for identity in [*source_identities, manifest_identity, *(item["file"] for item in resource_identities)]:
        if file_identity(identity["path"]) != identity:
            raise RuntimeError("A compile input changed during compilation: " + identity["path"])
    return {"sources": source_identities, "resources": resource_identities, "manifest": manifest_identity,
            "output": file_identity(destination), "command": command,
            "flags": {"architecture": "x64", "test_hooks": test_hooks, "admin": admin,
                      "check_only": check_only, "console": console}}


def build(output_root=None):
    if os.name != "nt" or not CSC.is_file():
        raise RuntimeError("Build on Windows with the existing x64 .NET Framework compiler")
    destination_root = Path(output_root).resolve() if output_root is not None else ROOT
    output = destination_root / "dist"
    artifacts = destination_root / "test-artifacts"
    compilations = []
    core_plan = ROOT / "plans/lockdown-2.1.6.03-core.json"
    launcher_sources = [ROOT / "src/ProcessPolicyLauncher.cs", ROOT / "src/TargetDiscovery.cs",
                        ROOT / "src/BrowserReadiness.cs", ROOT / "src/PolicyData.cs",
                        ROOT / "src/ImageDataNeutralizer.cs", ROOT / "src/Tracer.cs"]
    input_paths = [Path(__file__), *launcher_sources, ROOT / "tests/Fixture.cs", core_plan,
                   ROOT / "plans/generate_data_neutres.py",
                   ROOT / "plans/browser-extension-closures.json", ROOT / "src/app.manifest",
                   ROOT / "src/browser.manifest", ROOT / "src/Register-Protocol.ps1"]
    input_identities = [file_identity(path) for path in input_paths]
    compiler_identity = file_identity(CSC)
    plan_data = json.loads(core_plan.read_text(encoding="utf-8"))
    extension_plan = json.loads((ROOT / "plans/browser-extension-closures.json").read_text(encoding="utf-8"))
    plan_data["patches"].extend(extension_plan["patches"])
    plan_data["groups"] = ["process-close-and-office", extension_plan["group"]]
    output.mkdir(parents=True, exist_ok=True)
    plan = output / "patch-plan.json"
    plan.write_text(json.dumps(plan_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    compilations.append(compile_cs(launcher_sources, output / "LockDownBrowser.NoProcessGate.exe",
                                  [(plan, "PatchPlan.json")], admin=True))
    compilations.append(compile_cs(launcher_sources, output / "VerifyVersion.exe",
                                  [(plan, "PatchPlan.json")], check_only=True, console=True))
    # Experiment-only build: adds --patch-mode (immediate/none/deferred) for lab diagnostics.
    compilations.append(compile_cs(launcher_sources, artifacts / "ExperimentLauncher.exe",
                                  [(plan, "PatchPlan.json")], test_hooks=True, admin=True))
    shutil.copyfile(ROOT / "src/Register-Protocol.ps1", output / "Register-Protocol.ps1")
    fixture_dir = artifacts / "native fixture with spaces"
    fixture_dir.mkdir(parents=True, exist_ok=True)
    stub = fixture_dir / "native-stub.bin"
    # This is the entire native test function: mov eax,2 ; ret. No browser code runs.
    marker = b"NPG_NATIVE_FIXTURE_20261116"
    needle = bytes.fromhex("b8 02 00 00 00 c3") + marker
    stub.write_bytes(needle)
    fixture = fixture_dir / "ProcessGateFixture.exe"
    compilations.append(compile_cs(ROOT / "tests/Fixture.cs", fixture, [(stub, "NativeStub.bin")]))
    raw = fixture.read_bytes()
    assert raw.count(needle) == 1, "Native fixture marker is not unique"
    offset = raw.index(needle)
    pe = pefile.PE(data=raw)
    rva = pe.get_rva_from_offset(offset)
    section = pe.get_section_by_rva(rva)
    assert section is not None and section.Characteristics & 0x20000000
    fixture_plan = {
        "schemaVersion": 1, "targetName": fixture.name,
        "targetSha256": hashlib.sha256(raw).hexdigest(), "status": "harmless-test-fixture",
        "patches": [{"id": "native-return-value", "rva": hex(rva),
                     "expected": "b8 02 00 00 00", "replacement": "b8 01 00 00 00",
                     "rationale": "The fixture calls this native resource function and records its return value."}],
        # The marker string follows the six native bytes inside the same (executable)
        # section of the managed fixture, so the fixture plan explicitly opts in;
        # the launcher still refuses executable-section neutres for real plans.
        "dataNeutresAllowExecutableSection": True,
        "dataNeutres": [{"id": "fixture-marker-neutre", "rva": hex(pe.get_rva_from_offset(offset + 6)),
                         "expected": marker.hex(" "), "replacement": (b"NQ" + marker[2:]).hex(" "),
                         "rationale": "Harmless marker string; the fixture reads it back to prove the "
                                      "data-neutre machinery corrupts memory while the disk image stays intact."}],
    }
    fixture_plan_path = fixture_dir / "fixture-plan.json"
    fixture_plan_path.write_text(json.dumps(fixture_plan, indent=2) + "\n", encoding="utf-8")
    fixture_launcher = fixture_dir / "FixtureLauncher.exe"
    compilations.append(compile_cs(launcher_sources, fixture_launcher,
                                  [(fixture_plan_path, "PatchPlan.json")], test_hooks=True))
    startup_plan = dict(fixture_plan, readinessWindowClass=STARTUP_FIXTURE_CLASS,
                        readinessTimeoutMilliseconds=5000, status="harmless-startup-fixture")
    startup_plan_path = fixture_dir / "startup-fixture-plan.json"
    startup_plan_path.write_text(json.dumps(startup_plan, indent=2) + "\n", encoding="utf-8")
    startup_launcher = fixture_dir / "StartupFixtureLauncher.exe"
    # Use the production compilation conditions, changing only elevation and the embedded target plan.
    compilations.append(compile_cs(launcher_sources, startup_launcher, [(startup_plan_path, "PatchPlan.json")]))
    timeout_plan_path = fixture_dir / "timeout-fixture-plan.json"
    timeout_plan_path.write_text(json.dumps(dict(startup_plan, readinessTimeoutMilliseconds=250), indent=2) + "\n",
                                 encoding="utf-8")
    timeout_launcher = fixture_dir / "TimeoutFixtureLauncher.exe"
    compilations.append(compile_cs(launcher_sources, timeout_launcher, [(timeout_plan_path, "PatchPlan.json")]))
    visible_plan_path = fixture_dir / "visible-fixture-plan.json"
    visible_plan_path.write_text(json.dumps(dict(startup_plan, readinessWindowVisible=True,
                                                 readinessTimeoutMilliseconds=1500), indent=2) + "\n",
                                 encoding="utf-8")
    visible_launcher = fixture_dir / "VisibleFixtureLauncher.exe"
    compilations.append(compile_cs(launcher_sources, visible_launcher, [(visible_plan_path, "PatchPlan.json")]))
    artifact_paths = [plan, output / "Register-Protocol.ps1", stub, fixture_plan_path,
                      startup_plan_path, timeout_plan_path, visible_plan_path]
    manifest = {"schema_version": 2, "production_launcher": str(output / "LockDownBrowser.NoProcessGate.exe"),
                "production_plan": str(plan), "fixture": str(fixture), "fixture_launcher": str(fixture_launcher),
                "fixture_startup_launcher": str(startup_launcher), "fixture_timeout_launcher": str(timeout_launcher),
                "fixture_visible_launcher": str(visible_launcher),
                "fixture_startup_class": STARTUP_FIXTURE_CLASS,
                "fixture_rva": hex(rva), "fixture_sha256": fixture_plan["targetSha256"], "compiler": str(CSC),
                "launcher_source_sha256": hashlib.sha256((ROOT / "src/ProcessPolicyLauncher.cs").read_bytes()).hexdigest(),
                "fixture_source_sha256": hashlib.sha256((ROOT / "tests/Fixture.cs").read_bytes()).hexdigest(),
                "compiler_identity": compiler_identity, "input_files": input_identities,
                "artifact_files": [file_identity(path) for path in artifact_paths] + [item["output"] for item in compilations],
                "compilations": compilations}
    validate_manifest(manifest)
    (artifacts / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path,
                        help="Write dist and test artifacts to an isolated directory instead of this workspace")
    arguments = parser.parse_args()
    build(arguments.output_root)
