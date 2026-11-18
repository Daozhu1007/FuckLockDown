"""Rebuild the pending queue with short, hang-proof commands.

Usage: python requeue_controls.py [dialog-click|clean]
"""
import base64
import gzip
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from enqueue_cmd import enqueue_text

ROOT = Path(__file__).resolve().parent
MODE = sys.argv[1] if len(sys.argv) > 1 else "dialog-click"
TARGET_NAME = "OriginalControlsDialog.ps1" if MODE == "dialog-click" else "OriginalControlsClean.ps1"
script = (ROOT / "guest" / "OriginalControls.ps1").read_text(encoding="utf-8-sig")

# 1) Write the variant (prefix + script) into the guest,
#    decompressing the gzip payload BEFORE writing it to disk.
body = ("$controlMode='" + MODE + "';$controlSeconds=60;\n" + script).encode("utf-8")
payload = base64.b64encode(gzip.compress(body, 9)).decode()
expected = hashlib.sha256(body).hexdigest()
write_cmd = (
    "$g=[Convert]::FromBase64String('" + payload + "');"
    "$i=New-Object IO.MemoryStream(,$g);"
    "$z=New-Object IO.Compression.GzipStream($i,[IO.Compression.CompressionMode]::Decompress);"
    "$o=New-Object IO.MemoryStream;"
    "$z.CopyTo($o);"
    "[IO.File]::WriteAllBytes('C:\\NpgLab\\" + TARGET_NAME + "',$o.ToArray());"
    "if((Get-FileHash C:\\NpgLab\\" + TARGET_NAME + " -Algorithm SHA256).Hash.ToLower() -ne '" + expected + "'){throw 'hash mismatch'};"
    "'script written'"
)
enqueue_text(write_cmd, 30)
print("expected sha256:", expected)

# 2) Start the control detached; this command returns immediately.
enqueue_text(
    "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',"
    "'-File','C:\\NpgLab\\" + TARGET_NAME + "' -WindowStyle Hidden; 'control detached'",
    30,
)
print("enqueued write + detached start for", MODE)
