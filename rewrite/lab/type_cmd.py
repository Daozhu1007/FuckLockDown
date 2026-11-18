"""Robust QMP keyboard typer for the lab VM: longer Run-dialog settle time, slower keys."""
import json
import socket
import sys
import time

QMP = ("127.0.0.1", 18029)


def qmp(command, arguments=None):
    with socket.create_connection(QMP, timeout=15) as conn:
        reader = conn.makefile("rb")
        json.loads(reader.readline())
        for value in ({"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments or {}}):
            conn.sendall(json.dumps(value).encode("utf-8") + b"\n")
            while True:
                response = json.loads(reader.readline())
                if "return" in response or "error" in response:
                    break
            if "error" in response:
                raise RuntimeError(response["error"])
        return response


PLAIN = {" ": "spc", ".": "dot", "/": "slash", "\\": "backslash", "-": "minus",
         "=": "equal", ";": "semicolon", "'": "apostrophe", ",": "comma",
         "[": "bracket_left", "]": "bracket_right", "`": "grave_accent"}
SHIFTED = {":": "semicolon", '"': "apostrophe", "+": "equal", "_": "minus",
           "|": "backslash", "?": "slash", "(": "9", ")": "0", "$": "4",
           "&": "7", "!": "1", "@": "2", "#": "3", "%": "5", "^": "6",
           "*": "8", "<": "comma", ">": "dot", "{": "bracket_left", "}": "bracket_right"}


def type_text(text, hold_ms=35, gap=0.035):
    for character in text:
        shift = character.isupper() or character in SHIFTED
        key = SHIFTED.get(character, PLAIN.get(character, character.lower()))
        if not (character.isascii() and (character.isalnum() or character in PLAIN or character in SHIFTED)):
            raise ValueError("Unsupported character: " + repr(character))
        keys = ([{"type": "qcode", "data": "shift"}] if shift else []) + [{"type": "qcode", "data": key}]
        qmp("send-key", {"keys": keys, "hold-time": hold_ms})
        time.sleep(gap)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    if mode == "type":
        # Raw typing into whatever has focus, then Enter. No Win+R prefix.
        type_text(sys.argv[2])
        time.sleep(0.4)
        qmp("send-key", {"keys": [{"type": "qcode", "data": "ret"}], "hold-time": 40})
        print(json.dumps({"typed_raw": True, "characters": len(sys.argv[2])}))
    elif mode == "run":
        # Win+R, settle, then type the command and press Enter.
        qmp("send-key", {"keys": [{"type": "qcode", "data": "meta_l"}, {"type": "qcode", "data": "r"}], "hold-time": 60})
        time.sleep(2.0)
        type_text(sys.argv[2])
        time.sleep(0.4)
        qmp("send-key", {"keys": [{"type": "qcode", "data": "ret"}], "hold-time": 40})
        print(json.dumps({"typed": True, "characters": len(sys.argv[2])}))
    elif mode == "key":
        qmp("send-key", {"keys": [{"type": "qcode", "data": sys.argv[2]}], "hold-time": 40})
        print(json.dumps({"pressed": sys.argv[2]}))


if __name__ == "__main__":
    main()
