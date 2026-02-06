#!/usr/bin/env python3

import argparse
import json
import socket
import sys


def send_json_line(sock: socket.socket, obj: dict) -> dict:
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    sock.sendall(line.encode("utf-8"))
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("automation server closed connection")
        buf += chunk
    resp_line, _rest = buf.split(b"\n", 1)
    return json.loads(resp_line.decode("utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Simple JSON-line TCP client for Godot automation server.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=24680)
    ap.add_argument("--token", default="")
    ap.add_argument("--method", default="ping")
    ap.add_argument("--params-json", default="{}")
    ap.add_argument("--id", type=int, default=1)
    args = ap.parse_args()

    try:
        params = json.loads(args.params_json) if args.params_json else {}
    except Exception:
        params = {}

    with socket.create_connection((args.host, args.port), timeout=2.0) as sock:
        sock.settimeout(5.0)
        if args.token:
            auth = {"id": 0, "method": "auth", "params": {"token": args.token}}
            auth_resp = send_json_line(sock, auth)
            print(json.dumps(auth_resp))
        payload = {"id": args.id, "method": args.method, "params": params}
        resp = send_json_line(sock, payload)
        print(json.dumps(resp))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

