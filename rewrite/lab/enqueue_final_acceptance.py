"""Final acceptance of the production launcher (8d42637...) via detached execution.

Enqueues two SHORT commands (the V3 agent reliably hangs on long captures):
  1. write AcceptanceDetached.ps1 into the guest (gzip payload, decompress on
     the guest, SHA-256 check);
  2. start it detached - the script itself uploads its result via /upload and
     the agent never has to wait for it.
"""
import base64
import gzip
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from enqueue_cmd import enqueue_text

ROOT = Path(__file__).resolve().parent
PRODUCTION = "12f8d8364b3804bf191a07ce2a296256821d61c7dd60ebf67e294b4ea537ff64"
script = (ROOT / "guest" / "AcceptanceTest.ps1").read_text(encoding="utf-8-sig")

prefix = (
    "$acceptMode='patched';"
    "$acceptSeconds=45;"
    "$expectedLauncherHash='" + PRODUCTION + "';"
)
body = (prefix + script).encode("utf-8")
payload = base64.b64encode(gzip.compress(body, 9)).decode()
expected = hashlib.sha256(body).hexdigest()

write_cmd = (
    "$g=[Convert]::FromBase64String('" + payload + "');"
    "$i=New-Object IO.MemoryStream(,$g);"
    "$z=New-Object IO.Compression.GzipStream($i,[IO.Compression.CompressionMode]::Decompress);"
    "$o=New-Object IO.MemoryStream;"
    "$z.CopyTo($o);"
    "[IO.File]::WriteAllBytes('C:\\NpgLab\\AcceptanceDetached.ps1',$o.ToArray());"
    "if((Get-FileHash C:\\NpgLab\\AcceptanceDetached.ps1 -Algorithm SHA256).Hash.ToLower() -ne '" + expected + "'){throw 'hash mismatch'};"
    "'acceptance script written'"
)
enqueue_text(write_cmd, 30)
print("expected sha256:", expected)

start_cmd = (
    "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',"
    "'-File','C:\\NpgLab\\AcceptanceDetached.ps1' -WindowStyle Hidden; 'acceptance detached'"
)
enqueue_text(start_cmd, 30)
print("enqueued write + detached start; production", PRODUCTION)
