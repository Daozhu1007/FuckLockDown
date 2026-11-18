"""Split the experiment launcher into base64 chunks and enqueue transfer + run commands."""
import base64
import gzip
import hashlib
import json
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EXE = Path(r'D:/Code/FuckLockDown/rewrite/test-artifacts/ExperimentLauncher.exe')


def enqueue_script(script: str, timeout: int) -> str:
    command_id = str(time.time_ns()) + "-" + uuid.uuid4().hex[:8]
    value = {"id": command_id, "timeout": timeout,
             "encoded": base64.b64encode(script.encode("utf-16le")).decode("ascii")}
    target = ROOT / "queue" / (command_id + ".json")
    tmp = target.with_suffix(".pending")
    tmp.write_text(json.dumps(value, indent=2), encoding="utf-8")
    tmp.replace(target)
    print(command_id)
    return command_id


def main():
    raw = EXE.read_bytes()
    expected = hashlib.sha256(raw).hexdigest()
    b64 = base64.b64encode(gzip.compress(raw, 9)).decode()
    chunk_chars = 8000
    parts = [b64[i:i + chunk_chars] for i in range(0, len(b64), chunk_chars)]

    common = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); "
    for index, part in enumerate(parts):
        if index == 0:
            body = "$p = '" + part + "'; [IO.File]::WriteAllText('C:\\NpgLab\\exp_payload.b64', $p); 'chunk0 len ' + $p.Length"
        elif index < len(parts) - 1:
            body = "$p = '" + part + "'; [IO.File]::AppendAllText('C:\\NpgLab\\exp_payload.b64', $p); 'chunk" + str(index) + " len ' + $p.Length"
        else:
            body = ("Add-Type -AssemblyName System.IO.Compression; "
                    "$p = '" + part + "'; [IO.File]::AppendAllText('C:\\NpgLab\\exp_payload.b64', $p); "
                    "$gz = [Convert]::FromBase64String([IO.File]::ReadAllText('C:\\NpgLab\\exp_payload.b64')); "
                    "$in = New-Object IO.MemoryStream(,$gz); "
                    "$gs = New-Object IO.Compression.GzipStream($in, [IO.Compression.CompressionMode]::Decompress); "
                    "$out = New-Object IO.MemoryStream; $gs.CopyTo($out); "
                    "[IO.File]::WriteAllBytes('C:\\NpgLab\\ExperimentLauncher.exe', $out.ToArray()); "
                    "(Get-FileHash 'C:\\NpgLab\\ExperimentLauncher.exe' -Algorithm SHA256).Hash.ToLower()")
        enqueue_script(common + "$ErrorActionPreference='Stop'; " + body, 60)

    script_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(r'D:/Code/FuckLockDown/rewrite/lab/guest/ExperimentRun.ps1')
    if script_path.name == 'ExperimentRun.ps1':
        experiment = script_path.read_text(encoding='utf-8-sig')
        experiment = experiment.replace(
            "Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/VerifyVersion.exe') -Headers $headers -OutFile (Join-Path $lab 'ExperimentLauncher.exe') -TimeoutSec 180\n",
            "")
        run_script = common + "$mode = '" + (sys.argv[1] if len(sys.argv) > 1 else 'trace') + "'; " + experiment
    else:
        run_script = common + script_path.read_text(encoding='utf-8-sig')

    print('expected hash:', expected)
    print('chunk chars:', [len(x) for x in parts])
    print('run chars:', len(run_script))
    enqueue_script(run_script, 280)


if __name__ == '__main__':
    main()
