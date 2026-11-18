"""Isolated QEMU/KVM lab controller. Run prepare/start/serve inside WSL.

No host physical disk, host user profile or writable host share is attached to
the guest. The blank qcow2 image is the only disk Windows Setup can erase.
"""

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import signal
import shutil
import socket
import subprocess
import time
import uuid
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
PORT = 18028
QMP = 18029


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def configuration():
    path = ROOT / "secrets.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    value = {"token": secrets.token_hex(24), "password": "NpgLab!" + secrets.token_hex(8)}
    save(path, value)
    return value


def prepare():
    if os.name != "posix":
        raise RuntimeError("Run lab preparation inside WSL")
    config = configuration()
    media = ROOT / "tools-media"
    media.mkdir(exist_ok=True)
    for name in ("Bootstrap.ps1", "GuestAgent.ps1"):
        shutil.copyfile(ROOT / "guest" / name, media / name)
    save(media / "config.json", {"token": config["token"], "endpoint": f"http://10.0.2.2:{PORT}"})
    answer = (ROOT / "unattend.xml").read_text(encoding="utf-8").replace("@@PASSWORD@@", escape(config["password"]))
    (media / "Autounattend.xml").write_text(answer, encoding="utf-8")
    subprocess.run(["genisoimage", "-quiet", "-J", "-R", "-V", "NPGTOOLS", "-o", str(ROOT / "tools.iso"), str(media)], check=True)
    disk = ROOT / "windows.qcow2"
    if not disk.exists():
        subprocess.run(["qemu-img", "create", "-f", "qcow2", str(disk), "64G"], check=True)
    variables = ROOT / "OVMF_VARS.fd"
    if not variables.exists():
        shutil.copyfile("/usr/share/OVMF/OVMF_VARS_4M.ms.fd", variables)
    for name in ("reports", "queue", "sent", "tpm"):
        (ROOT / name).mkdir(exist_ok=True)
    print(json.dumps({"tools_iso": str(ROOT / "tools.iso"), "blank_vm_disk": str(disk)}))


def serve():
    config = configuration()
    artifacts = {
        "LockDownBrowser-2-1-6-03-356540564.msi": PROJECT / "LockDownBrowser-2-1-6-03-356540564.msi",
        "LockDownBrowser.NoProcessGate.exe": ROOT.parent / "dist/LockDownBrowser.NoProcessGate.exe",
        "VerifyVersion.exe": ROOT.parent / "dist/VerifyVersion.exe",
        "patch-plan.json": ROOT.parent / "dist/patch-plan.json",
        "Register-Protocol.ps1": ROOT.parent / "dist/Register-Protocol.ps1",
        "iris-vm.zip": ROOT / "iris-vm.zip",
    }

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def authenticated(self):
            if self.headers.get("X-Lab-Token") != config["token"]:
                self.send_error(403)
                return False
            return True

        def send_json(self, value):
            raw = json.dumps(value).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if not self.authenticated():
                return
            if self.path == "/command":
                available = sorted((ROOT / "queue").glob("*.json"))
                if not available:
                    return self.send_json(None)
                path = available[0]
                command = json.loads(path.read_text(encoding="utf-8"))
                path.replace(ROOT / "sent" / path.name)
                return self.send_json(command)
            prefix = "/artifact/"
            if self.path.startswith(prefix) and self.path[len(prefix):] in artifacts:
                path = artifacts[self.path[len(prefix):]]
                self.send_response(200)
                self.send_header("Content-Length", str(path.stat().st_size))
                self.end_headers()
                with path.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile, 1024 * 1024)
                return
            self.send_error(404)

        def do_POST(self):
            if not self.authenticated():
                return
            match = re.fullmatch(r"/upload/([A-Za-z0-9_.-]{1,100})", self.path)
            length = int(self.headers.get("Content-Length", "0"))
            if not match or length < 1 or length > 8 * 1024 * 1024:
                return self.send_error(400)
            raw = self.rfile.read(length)
            json.loads(raw)
            path = ROOT / "reports" / match[1]
            temporary = path.with_suffix(path.suffix + ".pending")
            temporary.write_bytes(raw)
            temporary.replace(path)
            self.send_json({"ok": True})

    print(json.dumps({"server": f"127.0.0.1:{PORT}"}), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


def qmp(command, arguments=None):
    with socket.create_connection(("127.0.0.1", QMP), timeout=10) as connection:
        reader = connection.makefile("rb")
        json.loads(reader.readline())
        for value in ({"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments or {}}):
            connection.sendall(json.dumps(value).encode("utf-8") + b"\n")
            while True:
                response = json.loads(reader.readline())
                if "return" in response or "error" in response:
                    break
            if "error" in response:
                raise RuntimeError(response["error"])
        return response


def start(install=False, attach_tools=False):
    if os.name != "posix":
        raise RuntimeError("Start this lab inside WSL")
    media_path = ROOT / "media.json"
    if not media_path.exists():
        raise RuntimeError("Evaluation ISO download has not finished")
    metadata = json.loads(media_path.read_text(encoding="utf-8"))
    iso = ROOT / "windows-eval.iso"
    if iso.stat().st_size != metadata["bytes"]:
        raise RuntimeError("Unexpected evaluation ISO size")
    # No physical-device paths are accepted: every writable guest disk is in this task's lab directory.
    disk = (ROOT / "windows.qcow2").resolve()
    if disk.parent != ROOT.resolve() or not disk.is_file():
        raise RuntimeError("Invalid VM disk path")
    control = Path("/tmp/npg-lab-tpm.sock")
    if control.exists():
        raise RuntimeError("A TPM control socket already exists; inspect the existing lab before starting another")
    subprocess.run(["swtpm", "socket", "--tpm2", "--tpmstate", "dir=" + str(ROOT / "tpm"),
                    "--ctrl", "type=unixio,path=" + str(control), "--log", "file=" + str(ROOT / "tpm.log"),
                    "--pid", "file=" + str(ROOT / "tpm.pid"), "--daemon"], check=True)
    command = ["qemu-system-x86_64", "-name", "NpgCompatibilityLab", "-machine", "q35,accel=kvm,smm=on",
               "-cpu", "host,kvm=off,hypervisor=off", "-smp", "4", "-m", "4096",
               "-global", "driver=cfi.pflash01,property=secure,value=on",
               "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd",
               "-drive", "if=pflash,unit=1,format=raw,file=" + str(ROOT / "OVMF_VARS.fd"),
               "-drive", "if=none,id=system,format=qcow2,file=" + str(disk),
               "-device", "ide-hd,drive=system,bus=ide.0,bootindex=2,model=Local Storage SSD,serial=LAB202611170001"]
    # The tools CD is a read-only delivery channel for the guest agent, but an
    # attached optical drive breaks the browser's VM-detection stealth (the
    # 2026-11-17 passing configuration had none), so it is opt-in only.
    if attach_tools:
        command += ["-drive", "if=none,id=tools,format=raw,media=cdrom,readonly=on,file=" + str(ROOT / "tools.iso"),
                    "-device", "ide-cd,drive=tools,bus=ide.2,model=Local Tools Drive"]
    if install:
        command += ["-drive", "if=none,id=install,format=raw,media=cdrom,readonly=on,file=" + str(iso),
                    "-device", "ide-cd,drive=install,bus=ide.1,bootindex=1,model=Local Optical Drive"]
    command += ["-chardev", "socket,id=chrtpm,path=" + str(control),
               "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis,tpmdev=tpm0",
               "-smbios", "type=1,manufacturer=LocalLab,product=CompatibilityTest,serial=NPGLAB20261116",
               "-nic", "user,model=e1000e", "-vga", "std", "-display", "none",
               "-qmp", f"tcp:127.0.0.1:{QMP},server=on,wait=off", "-rtc", "base=localtime"]
    log = (ROOT / "qemu.log").open("ab")
    guest_environment = dict(os.environ)
    guest_environment["TZ"] = "Asia/Shanghai"
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                               start_new_session=True, env=guest_environment)
    save(ROOT / "vm.json", {"pid": process.pid, "command": command, "disk": str(disk)})
    server_log = (ROOT / "server.log").open("ab")
    server = subprocess.Popen(["python3", str(Path(__file__).resolve()), "serve"], stdin=subprocess.DEVNULL,
                              stdout=server_log, stderr=server_log, start_new_session=True)
    save(ROOT / "server.json", {"pid": server.pid})
    print(json.dumps({"vm_pid": process.pid, "server_pid": server.pid}), flush=True)
    initial_boot = ROOT / "first-boot-started.json"
    if install or not initial_boot.exists():
        save(initial_boot, {"time": time.time()})
        # Only the initial blank-disk installation receives keys automatically.
        for _ in range(12):
            time.sleep(0.5)
            try:
                qmp("send-key", {"keys": [{"type": "qcode", "data": "ret"}]})
            except OSError:
                pass


def enqueue(path, timeout):
    command_id = str(time.time_ns()) + "-" + uuid.uuid4().hex[:8]
    script = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " + path.read_text(encoding="utf-8-sig")
    value = {"id": command_id, "timeout": timeout,
             "encoded": base64.b64encode(script.encode("utf-16le")).decode("ascii")}
    target = ROOT / "queue" / (command_id + ".json")
    temporary = target.with_suffix(".pending")
    save(temporary, value)
    temporary.replace(target)
    print(json.dumps({"id": command_id, "reply": str(ROOT / "reports" / ("reply-" + command_id + ".json"))}))


def run_command(text):
    # Keyboard input is delivered only to this lab VM's QMP endpoint.
    qmp("send-key", {"keys": [{"type": "qcode", "data": "meta_l"}, {"type": "qcode", "data": "r"}], "hold-time": 60})
    time.sleep(0.5)
    plain = {" ": "spc", ".": "dot", "/": "slash", "\\": "backslash", "-": "minus",
             "=": "equal", ";": "semicolon", "'": "apostrophe", ",": "comma",
             "[": "bracket_left", "]": "bracket_right", "`": "grave_accent"}
    shifted = {":": "semicolon", '"': "apostrophe", "+": "equal", "_": "minus",
               "|": "backslash", "?": "slash", "(": "9", ")": "0", "$": "4",
               "&": "7", "!": "1", "@": "2", "#": "3", "%": "5", "^": "6",
               "*": "8", "<": "comma", ">": "dot", "{": "bracket_left", "}": "bracket_right"}
    for character in text:
        shift = character.isupper() or character in shifted
        key = shifted.get(character, plain.get(character, character.lower()))
        if not (character.isascii() and (character.isalnum() or character in plain or character in shifted)):
            raise ValueError("The lab keyboard helper only accepts supported ASCII")
        keys = ([{"type": "qcode", "data": "shift"}] if shift else []) + [{"type": "qcode", "data": key}]
        qmp("send-key", {"keys": keys, "hold-time": 10})
        time.sleep(0.025)
    qmp("send-key", {"keys": [{"type": "qcode", "data": "ret"}], "hold-time": 40})
    print(json.dumps({"command_typed": True, "characters": len(text)}))


def stop():
    try:
        qmp("quit")
    except (OSError, RuntimeError):
        pass
    for role, path in (("server", ROOT / "server.json"), ("tpm", ROOT / "tpm.pid")):
        if not path.exists():
            continue
        pid = json.loads(path.read_text())["pid"] if role == "server" else int(path.read_text().strip())
        command_path = Path(f"/proc/{pid}/cmdline")
        if not command_path.exists():
            continue
        command = command_path.read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
        if str(ROOT) not in command or (role == "tpm" and "swtpm" not in command):
            raise RuntimeError("Refusing to stop a PID that is no longer owned by this lab")
        os.kill(pid, signal.SIGTERM)
    control = Path("/tmp/npg-lab-tpm.sock")
    for _ in range(20):
        if not control.exists():
            break
        time.sleep(0.1)
    if control.is_socket():
        control.unlink()
    print(json.dumps({"lab_stopped": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("prepare", "serve", "status", "screenshot", "enter", "stop"):
        sub.add_parser(name)
    boot = sub.add_parser("start")
    boot.add_argument("--install", action="store_true")
    boot.add_argument("--attach-tools", action="store_true",
                      help="Attach the tools CD; breaks the browser's VM-detection stealth")
    queue = sub.add_parser("enqueue")
    queue.add_argument("script", type=Path)
    queue.add_argument("--timeout", type=int, default=120)
    keyboard = sub.add_parser("run-command")
    keyboard.add_argument("command")
    args = parser.parse_args()
    if args.action == "prepare": prepare()
    elif args.action == "start": start(args.install, args.attach_tools)
    elif args.action == "serve": serve()
    elif args.action == "status": print(json.dumps(qmp("query-status")))
    elif args.action == "enter": print(json.dumps(qmp("send-key", {"keys": [{"type": "qcode", "data": "ret"}]})))
    elif args.action == "screenshot":
        path = ROOT / "reports/screen.png"
        print(json.dumps(qmp("screendump", {"filename": str(path), "format": "png"})))
    elif args.action == "stop": stop()
    elif args.action == "enqueue": enqueue(args.script.resolve(), args.timeout)
    elif args.action == "run-command": run_command(args.command)


if __name__ == "__main__": main()
