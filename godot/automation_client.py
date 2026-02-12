#!/usr/bin/env python3

import argparse
import json
from automation_rpc import AutomationClient


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

    cli = AutomationClient(
        args.host,
        args.port,
        args.token,
        connect_timeout_s=2.0,
        call_timeout_s=5.0,
        start_id=args.id - 1,
    )
    try:
        resp = cli.call(args.method, params)
        print(json.dumps(resp))
    finally:
        cli.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
