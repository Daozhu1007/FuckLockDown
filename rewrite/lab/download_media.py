"""Download Microsoft's evaluation ISO into the isolated lab, with bounded ranges.

The URL comes from the English x64 link on Microsoft's Evaluation Center. This
only downloads data; it does not mount or install the operating system.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import re
import socket
import threading
import time
import urllib.request


ROOT = Path(__file__).resolve().parent
URL = "https://software-static.download.prss.microsoft.com/dbazure/26300.9457.260913-1737.26h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
SOURCE = "https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise"
DEST = ROOT / "windows-eval.iso"
CHUNK = 4 * 1024 * 1024
OPENER = urllib.request.build_opener()


def edge_opener(address):
    # Per-request routing to an address returned by the publisher's DNS. SNI,
    # Host and certificate validation still use the original Microsoft name.
    class Connection(http.client.HTTPSConnection):
        def connect(self):
            if self.host != "software-static.download.prss.microsoft.com":
                return super().connect()
            connection = socket.create_connection((address, self.port), self.timeout)
            self.sock = self._context.wrap_socket(connection, server_hostname=self.host)

    class Handler(urllib.request.HTTPSHandler):
        def https_open(self, request):
            return self.do_open(Connection, request, context=self._context)

    return urllib.request.build_opener(urllib.request.ProxyHandler({}), Handler())


def request(start, end):
    response = OPENER.open(urllib.request.Request(URL, headers={
        "Range": f"bytes={start}-{end}", "User-Agent": "Mozilla/5.0"
    }), timeout=30)
    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
    if response.status != 206 or not match or int(match[1]) != start or int(match[2]) != end:
        response.close()
        raise RuntimeError("Unexpected range response")
    return response, int(match[3])


def main():
    global OPENER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--edge", help="Optional publisher CDN IPv4 address; HTTPS identity remains unchanged")
    args = parser.parse_args()
    if args.edge:
        socket.inet_pton(socket.AF_INET, args.edge)
        OPENER = edge_opener(args.edge)
    ROOT.mkdir(exist_ok=True)
    first, total = request(0, 65535)
    first.close()
    state_path = ROOT / "download-state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state["url"] != URL or state["bytes"] != total or not DEST.exists() or DEST.stat().st_size != total:
            raise RuntimeError("Existing download identity does not match")
        if state.get("chunk_bytes") != CHUNK:
            print(json.dumps({"stage": "chunk-boundaries-changed", "old_checkpoints": len(state["complete"])}), flush=True)
            state["chunk_bytes"] = CHUNK
            state["complete"] = {}
    else:
        with DEST.open("xb") as stream:
            stream.truncate(total)
        state = {"url": URL, "bytes": total, "chunk_bytes": CHUNK, "complete": {}}
        state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")
    lock = threading.Lock()
    stopping = threading.Event()

    def download(index):
        if stopping.is_set():
            return index
        start = index * CHUNK
        end = min(total, start + CHUNK) - 1
        if str(index) in state["complete"]:
            return index
        for attempt in range(3):
            try:
                response, observed_total = request(start, end)
                if observed_total != total:
                    raise RuntimeError("Media changed during download")
                digest = hashlib.sha256()
                written = 0
                with response, DEST.open("r+b") as stream:
                    stream.seek(start)
                    while True:
                        if stopping.is_set():
                            return index
                        data = response.read(1024 * 1024)
                        if not data:
                            break
                        if written + len(data) > end - start + 1:
                            raise RuntimeError("Oversized range body")
                        stream.write(data)
                        digest.update(data)
                        written += len(data)
                if written != end - start + 1:
                    raise RuntimeError("Truncated media range")
                with lock:
                    state["complete"][str(index)] = digest.hexdigest()
                    pending = state_path.with_suffix(".pending")
                    pending.write_text(json.dumps(state, indent=2), encoding="utf-8")
                    pending.replace(state_path)
                return index
            except Exception as error:
                print(json.dumps({"chunk": index, "attempt": attempt + 1, "error": str(error)}), flush=True)
                if stopping.is_set() or attempt == 2:
                    stopping.set()
                    raise
                time.sleep(min(2 ** attempt, 8))

    count = (total + CHUNK - 1) // CHUNK
    print(json.dumps({"stage": "download", "bytes": total, "chunks": count, "already_complete": len(state["complete"])}), flush=True)
    reported = len(state["complete"])
    with ThreadPoolExecutor(max_workers=8) as workers:
        futures = [workers.submit(download, i) for i in range(count)]
        try:
            for future in as_completed(futures):
                future.result()
                completed = len(state["complete"])
                if completed >= reported + 64 or completed == count:
                    reported = completed
                    print(json.dumps({"chunks_complete": completed, "chunks_total": count}), flush=True)
        except BaseException:
            stopping.set()
            for future in futures:
                future.cancel()
            raise
    digest = hashlib.sha256()
    with DEST.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(data)
    manifest = {"path": str(DEST), "url": URL, "source_page": SOURCE, "bytes": total,
                "sha256": digest.hexdigest(), "publisher_digest_comparison": "not-provided-on-source-page",
                "https_hostname": "software-static.download.prss.microsoft.com", "cdn_edge_override": args.edge}
    (ROOT / "media.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"stage": "complete", "bytes": total, "sha256": digest.hexdigest()}), flush=True)


if __name__ == "__main__":
    main()
