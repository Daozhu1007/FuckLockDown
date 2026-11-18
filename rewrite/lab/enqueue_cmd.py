"""Windows-side enqueue helper (no wsl.exe needed): write a command for the lab queue."""
import base64
import gzip
import hashlib
import json
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _next_stamp() -> int:
    """Monotonic, collision-free stamp: always greater than every existing
    queue/sent id. time_ns() repeats inside tight loops and the string-sorted
    delivery then reorders commands (observed 2026-11-18)."""
    import re as _re
    base = time.time_ns()
    seen = []
    for folder in ("queue", "sent"):
        directory = ROOT / folder
        if not directory.exists():
            continue
        for entry in directory.glob("*.json"):
            match = _re.match(r"(\d+)-", entry.name)
            if match:
                seen.append(int(match.group(1)))
    if seen and base <= max(seen):
        base = max(seen) + 1
    return base


def enqueue_text(script: str, timeout: int) -> str:
    command_id = str(_next_stamp()) + "-" + uuid.uuid4().hex[:8]
    script = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " + script
    source = script.encode("utf-8")
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    transport = "utf16-base64"
    if len(encoded) > 24000:
        # CreateProcessW limits the complete command line to 32767 UTF-16 units.
        # GuestAgent adds its PowerShell arguments around this payload.
        payload = base64.b64encode(gzip.compress(source, mtime=0)).decode("ascii")
        wrapper = (
            "$packed=[Convert]::FromBase64String('" + payload + "');"
            "$inputStream=New-Object IO.MemoryStream(,$packed);"
            "$gzipStream=New-Object IO.Compression.GzipStream($inputStream,[IO.Compression.CompressionMode]::Decompress);"
            "$sourceReader=New-Object IO.StreamReader($gzipStream,[Text.Encoding]::UTF8);"
            "try{$sourceText=$sourceReader.ReadToEnd()}finally{$sourceReader.Dispose();$inputStream.Dispose()};"
            "& ([ScriptBlock]::Create($sourceText))"
        )
        encoded = base64.b64encode(wrapper.encode("utf-16le")).decode("ascii")
        transport = "gzip-utf8-in-utf16-base64"
    if len(encoded) > 30000:
        raise ValueError("Lab script is too large for the guest command line even after compression")
    value = {"id": command_id, "timeout": timeout,
             "encoded": encoded, "transport": transport,
             "source_sha256": hashlib.sha256(source).hexdigest(), "source_bytes": len(source)}
    target = ROOT / "queue" / (command_id + ".json")
    tmp = target.with_suffix(".pending")
    tmp.write_text(json.dumps(value, indent=2), encoding="utf-8")
    tmp.replace(target)
    print(command_id)
    return command_id


def enqueue(script_path: Path, timeout: int, prefix: str = "") -> str:
    return enqueue_text(prefix + script_path.read_text(encoding="utf-8-sig"), timeout)


if __name__ == "__main__":
    script = Path(sys.argv[1])
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 240
    prefix = sys.argv[3] if len(sys.argv) > 3 else ""
    enqueue(script, timeout, prefix)
