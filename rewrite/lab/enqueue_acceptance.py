"""Transfer an exact candidate and run the same guest acceptance scenario."""
import argparse
import base64
import gzip
import hashlib
from pathlib import Path

from enqueue_cmd import enqueue_text


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("launcher", type=Path)
    parser.add_argument("--mode", choices=("baseline", "patched", "both"), default="patched")
    parser.add_argument("--seconds", type=int, default=45)
    args = parser.parse_args()
    raw = args.launcher.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    payload = base64.b64encode(gzip.compress(raw, mtime=0)).decode("ascii")
    guest = r"C:\NpgLab\candidate-" + digest[:16] + ".exe"
    staging = guest + ".b64"
    parts = [payload[offset:offset + 8000] for offset in range(0, len(payload), 8000)]
    for index, part in enumerate(parts):
        method = "WriteAllText" if index == 0 else "AppendAllText"
        enqueue_text("$ErrorActionPreference='Stop';[IO.File]::" + method + "('" + staging + "','" + part + "');'chunk " + str(index) + "'", 30)
    decode = (
        "$ErrorActionPreference='Stop';"
        "$bytes=[Convert]::FromBase64String([IO.File]::ReadAllText('" + staging + "'));"
        "$inputStream=New-Object IO.MemoryStream(,$bytes);"
        "$gzipStream=New-Object IO.Compression.GzipStream($inputStream,[IO.Compression.CompressionMode]::Decompress);"
        "$outputStream=New-Object IO.MemoryStream;"
        "try{$gzipStream.CopyTo($outputStream);[IO.File]::WriteAllBytes('" + guest + "',$outputStream.ToArray())}"
        "finally{$outputStream.Dispose();$gzipStream.Dispose();$inputStream.Dispose()};"
        "if((Get-FileHash -LiteralPath '" + guest + "' -Algorithm SHA256).Hash.ToLowerInvariant() -ne '" + digest + "'){throw 'Candidate transfer hash mismatch'};"
    )
    enqueue_text(decode, 30)
    prefix = ("$acceptMode='" + args.mode + "';$acceptSeconds=" + str(args.seconds) + ";"
              "$expectedLauncherHash='" + digest + "';$acceptLauncherPath='" + guest + "';$acceptSkipDownload=$true;")
    command = enqueue_text(prefix + (ROOT / "guest/AcceptanceTest.ps1").read_text(encoding="utf-8-sig"),
                           args.seconds * (2 if args.mode == "both" else 1) + 120)
    print("candidate_sha256:", digest)
    print("acceptance_command:", command)


if __name__ == "__main__":
    main()
