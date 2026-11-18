"""Write a guest .ps1 to the guest disk and enqueue a detached start for it."""
import base64
import gzip
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from enqueue_cmd import enqueue_text

ROOT = Path(__file__).resolve().parent


def deliver_and_run(script_path: str, guest_name: str) -> None:
    body = (ROOT / script_path).read_text(encoding="utf-8-sig").encode("utf-8")
    payload = base64.b64encode(gzip.compress(body, 9)).decode()
    expected = hashlib.sha256(body).hexdigest()
    guest_path = "C:\\NpgLab\\" + guest_name
    write_cmd = (
        "$g=[Convert]::FromBase64String('" + payload + "');"
        "$i=New-Object IO.MemoryStream(,$g);"
        "$z=New-Object IO.Compression.GzipStream($i,[IO.Compression.CompressionMode]::Decompress);"
        "$o=New-Object IO.MemoryStream;$z.CopyTo($o);"
        "[IO.File]::WriteAllBytes('" + guest_path + "',$o.ToArray());"
        "if((Get-FileHash '" + guest_path + "' -Algorithm SHA256).Hash.ToLower() -ne '" + expected + "'){throw 'hash mismatch'};"
        "'script written: " + guest_name + "'"
    )
    enqueue_text(write_cmd, 30)
    enqueue_text(
        "Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',"
        "'-File','" + guest_path + "' -WindowStyle Hidden; 'detached: " + guest_name + "'",
        30,
    )
    print("enqueued write + detached start for", guest_name)


if __name__ == "__main__":
    deliver_and_run(sys.argv[1], sys.argv[2])
