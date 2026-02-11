#!/usr/bin/env python3

import argparse
import json
import math
import pathlib
import socket
import time
from typing import Any, Dict, List, Optional


class AutomationClient:
    def __init__(self, host: str, port: int, token: str):
        self._sock = socket.create_connection((host, port), timeout=4.0)
        self._sock.settimeout(40.0)
        self._id = 0
        self.log: List[Dict[str, Any]] = []
        if token:
            self.call_raw("auth", {"token": token})

    def close(self) -> None:
        try:
            self._sock.close()
        except Exception:
            pass

    def call_raw(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        if params is None:
            params = {}
        self._id += 1
        req = {"id": self._id, "method": method, "params": params}
        self._sock.sendall((json.dumps(req, separators=(",", ":")) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise RuntimeError("automation server closed connection")
            buf += chunk
        resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
        self.log.append({"t": time.time(), "req": req, "resp": resp})
        if not resp.get("ok"):
            raise RuntimeError(resp)
        return resp.get("result")

    def dump_tree(self, max_depth: int = 6) -> Dict[str, Any]:
        return self.call_raw("dump_node_tree", {"path": "/root", "max_depth": max_depth, "max_children": 256}) or {}

    def find_path(self, node_name: str, max_depth: int = 6) -> str:
        root = self.dump_tree(max_depth=max_depth)
        stack = [root]
        while stack:
            n = stack.pop()
            if isinstance(n, dict) and n.get("name") == node_name:
                return str(n.get("path"))
            if isinstance(n, dict):
                for c in n.get("children", []) or []:
                    stack.append(c)
        raise RuntimeError(f"node not found: {node_name}")


def bcc_cells(x0: int, x1: int, y0: int, y1: int, z0: int, z1: int) -> List[List[int]]:
    out: List[List[int]] = []
    for z in range(z0, z1 + 1):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if (x & 1) == (y & 1) == (z & 1):
                    out.append([x, y, z])
    return out


def parse_stats(raw: List[Any]) -> Dict[str, Any]:
    ints = [int(x) for x in raw]
    idx_base = 5
    stride = 14

    def slot(mid: int) -> Dict[str, Any]:
        b = idx_base + mid * stride
        count = ints[b + 0]
        mass_fixed = ints[b + 1]
        return {
            "count": count,
            "avg_speed": ((ints[b + 2] / 100.0) / count) if count else 0.0,
            "max_speed": ints[b + 3] / 1000.0,
            "overlap_static": ints[b + 4],
            "com": [
                (ints[b + 11] * 100.0 / mass_fixed) if mass_fixed else 0.0,
                (ints[b + 12] * 100.0 / mass_fixed) if mass_fixed else 0.0,
                (ints[b + 13] * 100.0 / mass_fixed) if mass_fixed else 0.0,
            ],
        }

    return {
        "particle_count": ints[1],
        "active": ints[2],
        "sand": slot(1),
        "water": slot(2),
    }


def run_paint_lab(cli: AutomationClient, outdir: pathlib.Path) -> Dict[str, Any]:
    voxel = cli.find_path("VoxelRenderer")
    cli.call_raw("set", {"path": voxel, "property": "mpm_stats_enabled", "value": True})
    cli.call_raw("set", {"path": voxel, "property": "mpm_stats_every", "value": 1})
    cli.call_raw("set", {"path": voxel, "property": "gravity_dir", "value": [0.0, -1.0, 0.0]})
    cli.call_raw("set", {"path": voxel, "property": "world_rotation", "value": [0.0, 0.0, 0.0]})
    cli.call_raw("call", {"path": voxel, "method": "automation_reset_empty", "args": []})

    wall = bcc_cells(52, 52, 8, 56, 22, 42)
    wall_set = int(cli.call_raw("call", {"path": voxel, "method": "automation_set_voxels", "args": [wall, 8]}) or 0)
    sand = bcc_cells(48, 54, 48, 56, 26, 38)
    sand_spawn = int(
        cli.call_raw("call", {"path": voxel, "method": "automation_spawn_cells", "args": [sand, 1, [0.0, 0.0, 0.0], 4.0, 0]})
        or 0
    )
    hole = bcc_cells(52, 52, 28, 32, 30, 34)
    hole_clear = int(cli.call_raw("call", {"path": voxel, "method": "automation_set_voxels", "args": [hole, 0]}) or 0)

    probes = [[52, 50, 30], [52, 30, 30], [50, 52, 30], [48, 20, 30]]
    t0 = time.time()
    samples: List[Dict[str, Any]] = []

    def sample(tag: str) -> None:
        raw = cli.call_raw("call", {"path": voxel, "method": "mpm_get_last_stats_raw", "args": []}) or []
        st = parse_stats(raw)
        st["tag"] = tag
        st["t_s"] = round(time.time() - t0, 3)
        st["column_sand"] = cli.call_raw("call", {"path": voxel, "method": "mpm_get_material_column_metrics", "args": [1]}) or {}
        req = int(cli.call_raw("call", {"path": voxel, "method": "mpm_request_discrete_audit", "args": []}) or 0)
        for _ in range(120):
            done = int(cli.call_raw("call", {"path": voxel, "method": "mpm_get_last_discrete_audit_frame", "args": []}) or 0)
            if done >= req:
                break
            time.sleep(0.02)
        audit = cli.call_raw("call", {"path": voxel, "method": "mpm_get_last_discrete_audit", "args": []}) or {}
        st["audit_global"] = audit.get("global", {}) if isinstance(audit, dict) else {}
        st["probe_mats"] = cli.call_raw("call", {"path": voxel, "method": "automation_get_cell_materials", "args": [probes]}) or {}
        st["snapshot"] = cli.call_raw("call", {"path": voxel, "method": "mpm_get_particle_snapshot", "args": [1, 64]}) or {}
        samples.append(st)

    time.sleep(1.0)
    sample("baseline")
    cli.call_raw("screenshot", {"path": str((outdir / "00_baseline.png").resolve())})

    for i, deg in enumerate([15, 30, 45, 60, 75, 90], start=1):
        cli.call_raw("set", {"path": voxel, "property": "world_rotation", "value": [0.0, 0.0, math.radians(deg)]})
        time.sleep(1.2)
        sample(f"roll_{deg}")
        cli.call_raw("screenshot", {"path": str((outdir / f"{i:02d}_roll_{deg}.png").resolve())})

    for k in range(10):
        time.sleep(1.0)
        sample(f"hold_{k + 1}")
    cli.call_raw("screenshot", {"path": str((outdir / "99_hold_end.png").resolve())})

    (outdir / "samples.json").write_text(json.dumps(samples, indent=2), encoding="utf-8")
    (outdir / "command_log.json").write_text(json.dumps(cli.log, indent=2), encoding="utf-8")
    summary = {
        "voxel_path": voxel,
        "wall_set": wall_set,
        "sand_spawn": sand_spawn,
        "hole_clear": hole_clear,
        "sample_count": len(samples),
        "first": samples[0] if samples else {},
        "last": samples[-1] if samples else {},
    }
    (outdir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main() -> int:
    ap = argparse.ArgumentParser(description="Automation runtime lab (property/set/call + metrics logging).")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=24680)
    ap.add_argument("--token", default="voxdebug")
    ap.add_argument("--scenario", choices=["paint_lab"], default="paint_lab")
    ap.add_argument("--outdir", default="")
    args = ap.parse_args()

    outdir = pathlib.Path(args.outdir) if args.outdir else pathlib.Path("runlogs/manual_debug/paint_runtime_lab_script")
    outdir.mkdir(parents=True, exist_ok=True)

    cli = AutomationClient(args.host, args.port, args.token)
    try:
        cli.call_raw("ping", {})
        if args.scenario == "paint_lab":
            summary = run_paint_lab(cli, outdir)
        else:
            raise RuntimeError(f"unsupported scenario: {args.scenario}")
    finally:
        cli.close()

    print(json.dumps(summary, indent=2))
    print(f"artifacts: {outdir.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
