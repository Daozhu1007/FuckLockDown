"""Windows-side QMP helper: screenshot or status from the lab VM."""
import json
import socket
import sys
from pathlib import Path

QMP = ("127.0.0.1", 18029)
ROOT = Path(__file__).resolve().parent


def qmp(command, arguments=None):
    with socket.create_connection(QMP, timeout=15) as conn:
        reader = conn.makefile("rb")
        json.loads(reader.readline())
        for value in ({"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments or {}}):
            conn.sendall(json.dumps(value).encode() + b"\n")
            while True:
                response = json.loads(reader.readline())
                if "return" in response or "error" in response:
                    break
            if "error" in response:
                raise RuntimeError(response["error"])
        return response


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    if action == "status":
        print(json.dumps(qmp("query-status")))
    elif action == "screenshot":
        out = ROOT / "reports" / (sys.argv[2] if len(sys.argv) > 2 else "screen.png")
        print(json.dumps(qmp("screendump", {"filename": str(out).replace("D:", "/mnt/d", 1).replace("\\", "/"), "format": "png"})))
