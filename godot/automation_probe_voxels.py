#!/usr/bin/env python3

import argparse
import json
import socket
import sys
import time
from typing import Optional, Tuple, Dict, Any


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


class AutomationClient:
    def __init__(self, host: str, port: int, token: str):
        self._sock = socket.create_connection((host, port), timeout=2.0)
        self._sock.settimeout(5.0)
        self._id = 1
        if token:
            resp = send_json_line(self._sock, {"id": 0, "method": "auth", "params": {"token": token}})
            if not resp.get("ok"):
                raise RuntimeError(f"auth failed: {resp}")

    def close(self):
        try:
            self._sock.close()
        except Exception:
            pass

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> dict:
        if params is None:
            params = {}
        self._id += 1
        resp = send_json_line(self._sock, {"id": self._id, "method": method, "params": params})
        if not resp.get("ok"):
            raise RuntimeError(f"automation error: {resp.get('error')}")
        return resp


def walk_dump(node: dict, fn):
    fn(node)
    for child in node.get("children", []) or []:
        if isinstance(child, dict):
            walk_dump(child, fn)


def find_paths(tree_dump: dict) -> Tuple[Optional[str], Optional[str]]:
    voxel_path: Optional[str] = None
    orbit_path: Optional[str] = None

    def scan(n: dict):
        nonlocal voxel_path, orbit_path
        name = n.get("name")
        path = n.get("path")
        if name == "VoxelRenderer" and voxel_path is None:
            voxel_path = path
        if name == "OrbitRig" and orbit_path is None:
            orbit_path = path

    walk_dump(tree_dump, scan)
    return voxel_path, orbit_path


def main() -> int:
    ap = argparse.ArgumentParser(description="Automation probe: orbit camera and move debug probe cell.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=24680)
    ap.add_argument("--token", default="voxdebug")
    ap.add_argument("--steps", type=int, default=24)
    ap.add_argument("--yaw-start", type=float, default=0.0)
    ap.add_argument("--yaw-end", type=float, default=6.283185307179586)
    ap.add_argument("--pitch", type=float, default=-0.35)
    ap.add_argument("--sleep-ms", type=int, default=200)
    ap.add_argument("--probe-x", type=int, default=12)
    ap.add_argument("--probe-y", type=int, default=12)
    ap.add_argument("--probe-z", type=int, default=12)
    ap.add_argument("--probe-stride", type=int, default=0)
    ap.add_argument("--debug-log-every", type=int, default=30)
    ap.add_argument("--debug-probe-every", type=int, default=30)
    ap.add_argument("--metrics-every", type=int, default=30)
    ap.add_argument("--sim-enabled", action=argparse.BooleanOptionalAction, default=True)
    ap.add_argument("--sim-every", type=int, default=1)
    ap.add_argument("--render-thread-ping", action="store_true")
    ap.add_argument("--voxel-path", default="")
    ap.add_argument("--orbit-path", default="")
    ap.add_argument("--dump-depth", type=int, default=6)
    args = ap.parse_args()

    cli = AutomationClient(args.host, args.port, args.token)
    try:
        print(f"ping={cli.call('ping').get('result')}")

        voxel_path = args.voxel_path or None
        orbit_path = args.orbit_path or None
        if voxel_path is None or orbit_path is None:
            dump = cli.call("dump_node_tree", {"path": "/root", "max_depth": args.dump_depth, "max_children": 128})
            voxel_path2, orbit_path2 = find_paths(dump.get("result", {}) or {})
            voxel_path = voxel_path or voxel_path2
            orbit_path = orbit_path or orbit_path2

        if not voxel_path:
            raise RuntimeError("could not find VoxelRenderer path (use --voxel-path or increase --dump-depth)")
        if not orbit_path:
            raise RuntimeError("could not find OrbitRig path (use --orbit-path or increase --dump-depth)")

        # Scene load and script init can lag a bit, so be willing to retry.
        chunk_grid = None
        chunk_size = None
        for _attempt in range(50):
            cg = cli.call("get", {"path": voxel_path, "property": "chunk_grid"}).get("result")
            cs = cli.call("get", {"path": voxel_path, "property": "chunk_size"}).get("result")
            if cg is not None and cs is not None:
                chunk_grid = int(cg)
                chunk_size = int(cs)
                break

            # Re-scan the node tree in case the main scene just changed.
            dump = cli.call("dump_node_tree", {"path": "/root", "max_depth": args.dump_depth, "max_children": 128})
            voxel_path2, orbit_path2 = find_paths(dump.get("result", {}) or {})
            voxel_path = voxel_path2 or voxel_path
            orbit_path = orbit_path2 or orbit_path
            time.sleep(0.1)

        if chunk_grid is None or chunk_size is None:
            raise RuntimeError(f"VoxelRenderer properties not ready at path={voxel_path}")
        grid_extent = chunk_grid * chunk_size
        print(f"voxel_path={voxel_path} orbit_path={orbit_path} grid_extent={grid_extent} chunk_grid={chunk_grid} chunk_size={chunk_size}")

        cli.call("set", {"path": voxel_path, "property": "debug_logging", "value": True})
        cli.call("set", {"path": voxel_path, "property": "debug_log_every", "value": int(args.debug_log_every)})
        cli.call("set", {"path": voxel_path, "property": "debug_probe_enabled", "value": True})
        cli.call("set", {"path": voxel_path, "property": "debug_probe_every", "value": int(args.debug_probe_every)})
        cli.call("set", {"path": voxel_path, "property": "metrics_every", "value": int(args.metrics_every)})
        cli.call("set", {"path": voxel_path, "property": "sim_enabled", "value": bool(args.sim_enabled)})
        cli.call("set", {"path": voxel_path, "property": "sim_every", "value": int(args.sim_every)})
        cli.call("set", {"path": voxel_path, "property": "debug_render_thread_ping", "value": bool(args.render_thread_ping)})

        cli.call("set", {"path": voxel_path, "property": "debug_probe_cell", "value": [int(args.probe_x), int(args.probe_y), int(args.probe_z)]})

        steps = max(1, int(args.steps))
        for i in range(steps + 1):
            ratio = i / float(steps)
            yaw = args.yaw_start + (args.yaw_end - args.yaw_start) * ratio
            cell_x = args.probe_x + i * args.probe_stride
            if grid_extent > 0:
                cell_x = ((cell_x % grid_extent) + grid_extent) % grid_extent

            cli.call("set", {"path": voxel_path, "property": "debug_probe_cell", "value": [int(cell_x), int(args.probe_y), int(args.probe_z)]})
            cli.call("set", {"path": orbit_path, "property": "rotation", "value": [float(args.pitch), float(yaw), 0.0]})
            print(f"step={i} yaw={yaw:.3f} cell=({cell_x},{args.probe_y},{args.probe_z})")
            time.sleep(max(0.0, args.sleep_ms / 1000.0))
    finally:
        cli.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
