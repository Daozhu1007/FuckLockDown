"""Deliver WatchFinal.ps1 to the guest and start it detached (hang-proof)."""
import base64
import gzip
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from enqueue_cmd import enqueue_text

ROOT = Path(__file__).resolve().parent
body = (ROOT / "guest" / "WatchFinal.ps1").read_text(encoding="utf-8-sig").encode("utf-8")
payload = base64.b64encode(gzip.compress(body, 9)).decode()
expected = hashlib.sha256(body).hexdigest()

write_cmd = (
    "$g=[Convert]::FromBase64String('" + payload + "');"
    "$i=New-Object IO.MemoryStream(,$g);"
    "$z=New-Object IO.Compression.GzipStream($i,[IO.Compression.CompressionMode]::Decompress);"
    "$o=New-Object IO.MemoryStream;"
    "$z.CopyTo($o);"
    "[IO.File]::WriteAllBytes('C:\\NpgLab\\WatchFinal.ps1',$o.ToArray());"
    "if((Get-FileHash C:\\NpgLab\\WatchFinal.ps1 -Algorithm SHA256).Hash.ToLower() -ne '" + expected + "'){throw 'hash mismatch'};"
    "'watcher written'"
)
enqueue_text(write_cmd, 30)
print("expected sha256:", expected)

start_cmd = (
    "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',"
    "'-File','C:\\NpgLab\\WatchFinal.ps1' -WindowStyle Hidden; 'watcher detached'"
)
enqueue_text(start_cmd, 30)
print("enqueued watcher write + detached start")
