"""Deliver TableHunter.exe to the guest in chunks, then start it detached.

With --reuse-b64, skip the chunk upload: the .b64 already on the guest is
assumed to be the current build (verified by hash after decompression).
"""
import base64
import gzip
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from enqueue_cmd import enqueue_text

ROOT = Path(__file__).resolve().parent
EXE = ROOT / "TableHunter.exe"
raw = EXE.read_bytes()
expected = hashlib.sha256(raw).hexdigest()
b64 = base64.b64encode(gzip.compress(raw, 9)).decode()

if "--reuse-b64" not in sys.argv:
    CHUNK = 8000
    parts = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
    target = "C:\\NpgLab\\TableHunter.exe.b64"
    print("expected sha256:", expected)
    print("chunks:", [len(p) for p in parts])
    for index, part in enumerate(parts):
        if index == 0:
            body = "[IO.File]::WriteAllText('" + target + "','" + part + "'); 'chunk0 ' + " + str(len(part))
        else:
            body = "[IO.File]::AppendAllText('" + target + "','" + part + "'); 'chunk" + str(index) + " ' + " + str(len(part))
        enqueue_text(body, 30)

# Decompress + hash-verify; Stop so a locked file fails loudly at this line.
decompress = (
    "$ErrorActionPreference='Stop';"
    "$b=[Convert]::FromBase64String([IO.File]::ReadAllText('C:\\NpgLab\\TableHunter.exe.b64'));"
    "$i=New-Object IO.MemoryStream(,$b);"
    "$z=New-Object IO.Compression.GzipStream($i,[IO.Compression.CompressionMode]::Decompress);"
    "$o=New-Object IO.MemoryStream;$z.CopyTo($o);"
    "[IO.File]::WriteAllBytes('C:\\NpgLab\\TableHunter.exe',$o.ToArray());"
    "if((Get-FileHash C:\\NpgLab\\TableHunter.exe -Algorithm SHA256).Hash.ToLower() -ne '" + expected + "'){throw 'hash mismatch'};"
    "'hunter written and verified'"
)
enqueue_text(decompress, 60)

start = (
    "Start-Process C:\\NpgLab\\TableHunter.exe -ArgumentList '--no-ui','--log','C:\\NpgLab\\hunter6.jsonl' "
    "-WindowStyle Hidden; 'hunter detached'"
)
enqueue_text(start, 30)
print("expected sha256:", expected)
print("enqueued verify + detached start")
