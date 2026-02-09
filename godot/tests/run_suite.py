#!/usr/bin/env python3

import argparse
import datetime as _dt
import json
import os
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def _send_json_line(sock: socket.socket, obj: dict) -> dict:
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
    def __init__(self, host: str, port: int, token: str, timeout_s: float = 2.0):
        self._sock = socket.create_connection((host, port), timeout=timeout_s)
        # Calls can block for multiple frames if the GPU stalls or the engine is busy.
        # Prefer a larger timeout + retries over flaking the whole suite.
        self._sock.settimeout(30.0)
        self._id = 1
        if token:
            resp = _send_json_line(self._sock, {"id": 0, "method": "auth", "params": {"token": token}})
            if not resp.get("ok"):
                raise RuntimeError(f"auth failed: {resp}")

    def close(self) -> None:
        try:
            self._sock.close()
        except Exception:
            pass

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> dict:
        if params is None:
            params = {}
        self._id += 1
        last_exc: Optional[Exception] = None
        for _attempt in range(2):
            try:
                resp = _send_json_line(self._sock, {"id": self._id, "method": method, "params": params})
                if not resp.get("ok"):
                    raise RuntimeError(f"automation error: {resp.get('error')}")
                return resp
            except socket.timeout as e:
                # Transient stalls happen on macOS/MoltenVK; retry once.
                last_exc = e
                time.sleep(0.1)
        raise last_exc  # type: ignore[misc]


def _walk_dump(node: dict, fn) -> None:
    fn(node)
    for child in node.get("children", []) or []:
        if isinstance(child, dict):
            _walk_dump(child, fn)


def _find_paths(tree_dump: dict) -> Tuple[Optional[str], Optional[str]]:
    voxel_path: Optional[str] = None
    orbit_path: Optional[str] = None

    def scan(n: dict) -> None:
        nonlocal voxel_path, orbit_path
        name = n.get("name")
        path = n.get("path")
        if name == "VoxelRenderer" and voxel_path is None:
            voxel_path = path
        if name == "OrbitRig" and orbit_path is None:
            orbit_path = path

    _walk_dump(tree_dump, scan)
    return voxel_path, orbit_path


def _find_first_path_by_name(tree_dump: dict, name: str) -> Optional[str]:
    found: Optional[str] = None

    def scan(n: dict) -> None:
        nonlocal found
        if found is not None:
            return
        if n.get("name") == name:
            found = n.get("path")

    _walk_dump(tree_dump, scan)
    return found


def _find_free_port(host: str = "127.0.0.1") -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((host, 0))
        s.listen(1)
        return int(s.getsockname()[1])


def _parse_stats_ints(ints: List[int]) -> Dict[str, Any]:
    # Must match godot/project/shaders/mpm_stats*.glsl and VoxelRenderer.gd parsing.
    IDX_BASE = 5
    MAT_SLOTS = 16
    SLOT_STRIDE = 14

    if len(ints) < (IDX_BASE + MAT_SLOTS * SLOT_STRIDE):
        raise ValueError(f"stats buffer too small: ints={len(ints)}")

    out: Dict[str, Any] = {
        "version": ints[0],
        "particle_count": ints[1],
        "active": ints[2],
        "inactive": ints[3],
        "nan": ints[4],
        "slots": [],
    }

    slots: List[Dict[str, Any]] = []
    total_mass = 0.0
    total_overlap = 0

    for mat_id in range(MAT_SLOTS):
        base = IDX_BASE + mat_id * SLOT_STRIDE
        count = ints[base + 0]
        mass_fixed = ints[base + 1]
        sum_speed_x100 = ints[base + 2]
        max_speed_x1000 = ints[base + 3]
        overlap_static = ints[base + 4]
        min_x = ints[base + 5]
        min_y = ints[base + 6]
        min_z = ints[base + 7]
        max_x = ints[base + 8]
        max_y = ints[base + 9]
        max_z = ints[base + 10]
        sum_mx = ints[base + 11]
        sum_my = ints[base + 12]
        sum_mz = ints[base + 13]

        mass = float(mass_fixed) / 10000.0
        avg_speed = 0.0
        if count > 0:
            avg_speed = (float(sum_speed_x100) / 100.0) / float(count)
        max_speed = float(max_speed_x1000) / 1000.0

        com = (0.0, 0.0, 0.0)
        if mass_fixed != 0:
            # sum_mx = sum(m*x)*100, mass_fixed = sum(m)*10000 => com = sum_mx*100/mass_fixed
            com = (
                float(sum_mx) * 100.0 / float(mass_fixed),
                float(sum_my) * 100.0 / float(mass_fixed),
                float(sum_mz) * 100.0 / float(mass_fixed),
            )

        bbox_valid = bool(count > 0 and min_x != 2147483647 and max_x != -2147483647)
        bbox_min = (float(min_x) / 1000.0, float(min_y) / 1000.0, float(min_z) / 1000.0)
        bbox_max = (float(max_x) / 1000.0, float(max_y) / 1000.0, float(max_z) / 1000.0)

        slot = {
            "mat_id": mat_id,
            "count": int(count),
            "mass": mass,
            "avg_speed": avg_speed,
            "max_speed": max_speed,
            "overlap_static": int(overlap_static),
            "com": com,
            "bbox_valid": bbox_valid,
            "bbox_min": bbox_min,
            "bbox_max": bbox_max,
        }
        slots.append(slot)
        total_mass += mass
        total_overlap += int(overlap_static)

    out["slots"] = slots
    out["total_mass"] = total_mass
    out["total_overlap_static"] = total_overlap
    return out


def _slot(stats: Dict[str, Any], mat_id: int) -> Dict[str, Any]:
    slots = stats.get("slots") or []
    if 0 <= mat_id < len(slots):
        return slots[mat_id]
    return {"mat_id": mat_id, "count": 0, "mass": 0.0, "avg_speed": 0.0, "max_speed": 0.0, "overlap_static": 0}


def _eval_scene(scene_cfg: Dict[str, Any], baseline: Dict[str, Any], final: Dict[str, Any]) -> Tuple[bool, List[str]]:
    failures: List[str] = []
    checks = scene_cfg.get("checks", {}) or {}

    nan_max = int(checks.get("nan_max", 0))
    if int(final.get("nan", 0)) > nan_max:
        failures.append(f"nan_count {final.get('nan')} > {nan_max}")

    total_mass_loss_frac_max = float(checks.get("total_mass_loss_frac_max", 0.01))
    base_mass = float(baseline.get("total_mass", 0.0))
    final_mass = float(final.get("total_mass", 0.0))
    if base_mass > 0.0:
        loss_frac = max(0.0, (base_mass - final_mass) / base_mass)
        if loss_frac > total_mass_loss_frac_max:
            failures.append(f"total_mass_loss_frac {loss_frac:.4f} > {total_mass_loss_frac_max:.4f}")

    mat_checks = scene_cfg.get("material_checks", []) or []
    for mc in mat_checks:
        mat_id = int(mc.get("mat_id", -1))
        if mat_id < 0:
            continue
        b = _slot(baseline, mat_id)
        f = _slot(final, mat_id)

        if "count_min" in mc:
            cmin = int(mc["count_min"])
            if int(f.get("count", 0)) < cmin:
                failures.append(f"mat={mat_id} count {f.get('count')} < {cmin}")

        if "mass_min" in mc:
            mmin = float(mc["mass_min"])
            if float(f.get("mass", 0.0)) < mmin:
                failures.append(f"mat={mat_id} mass {f.get('mass'):.4f} < {mmin:.4f}")

        if "count_delta_min" in mc:
            dmin = int(mc["count_delta_min"])
            dc = int(f.get("count", 0)) - int(b.get("count", 0))
            if dc < dmin:
                failures.append(f"mat={mat_id} count_delta {dc} < {dmin}")

        if "mass_delta_min" in mc:
            dmin = float(mc["mass_delta_min"])
            dm = float(f.get("mass", 0.0)) - float(b.get("mass", 0.0))
            if dm < dmin:
                failures.append(f"mat={mat_id} mass_delta {dm:.4f} < {dmin:.4f}")

        if "com_y_drop_min" in mc:
            dmin = float(mc["com_y_drop_min"])
            by = float((b.get("com") or (0.0, 0.0, 0.0))[1])
            fy = float((f.get("com") or (0.0, 0.0, 0.0))[1])
            drop = by - fy
            if drop < dmin:
                failures.append(f"mat={mat_id} com_y_drop {drop:.4f} < {dmin:.4f}")

        if "mass_loss_frac_max" in mc:
            frac_max = float(mc["mass_loss_frac_max"])
            bm = float(b.get("mass", 0.0))
            fm = float(f.get("mass", 0.0))
            if bm > 0.0:
                loss_frac = max(0.0, (bm - fm) / bm)
                if loss_frac > frac_max:
                    failures.append(f"mat={mat_id} mass_loss_frac {loss_frac:.4f} > {frac_max:.4f}")

        if "overlap_static_max" in mc:
            ov_max = int(mc["overlap_static_max"])
            ov = int(f.get("overlap_static", 0))
            if ov > ov_max:
                failures.append(f"mat={mat_id} overlap_static {ov} > {ov_max}")

        if "avg_speed_final_max" in mc:
            sp_max = float(mc["avg_speed_final_max"])
            sp = float(f.get("avg_speed", 0.0))
            if sp > sp_max:
                failures.append(f"mat={mat_id} avg_speed_final {sp:.4f} > {sp_max:.4f}")

        if "max_speed_final_max" in mc:
            sp_max = float(mc["max_speed_final_max"])
            sp = float(f.get("max_speed", 0.0))
            if sp > sp_max:
                failures.append(f"mat={mat_id} max_speed_final {sp:.4f} > {sp_max:.4f}")

    return (len(failures) == 0), failures


def _wait_for_voxel_renderer(cli: AutomationClient, timeout_s: float = 10.0) -> Tuple[str, Optional[str]]:
    deadline = time.time() + timeout_s
    voxel_path: Optional[str] = None
    orbit_path: Optional[str] = None
    while time.time() < deadline:
        dump = cli.call("dump_node_tree", {"path": "/root", "max_depth": 6, "max_children": 128}).get("result") or {}
        voxel_path2, orbit_path2 = _find_paths(dump)
        voxel_path = voxel_path2 or voxel_path
        orbit_path = orbit_path2 or orbit_path
        if voxel_path:
            return voxel_path, orbit_path
        time.sleep(0.1)
    raise RuntimeError("could not find VoxelRenderer in node tree")


def _wait_for_stats(cli: AutomationClient, voxel_path: str, min_frame: int, timeout_s: float) -> int:
    deadline = time.time() + timeout_s
    last = -1
    while time.time() < deadline:
        resp = cli.call("call", {"path": voxel_path, "method": "mpm_get_last_stats_frame", "args": []})
        frame = int(resp.get("result") or 0)
        last = frame
        if frame > min_frame:
            return frame
        time.sleep(0.05)
    raise RuntimeError(f"stats did not advance (last={last})")


def _fetch_stats(cli: AutomationClient, voxel_path: str) -> Dict[str, Any]:
    raw = cli.call("call", {"path": voxel_path, "method": "mpm_get_last_stats_raw", "args": []}).get("result")
    if not isinstance(raw, list):
        raise RuntimeError(f"unexpected stats raw type: {type(raw)}")
    ints = [int(x) for x in raw]
    return _parse_stats_ints(ints)


def _launch_scene(
    engine: Path,
    project_dir: Path,
    scene: str,
    host: str,
    port: int,
    token: str,
    log_file: Path,
) -> subprocess.Popen:
    cmd = [
        str(engine),
        "--path",
        str(project_dir),
        "--scene",
        scene,
        "--automation",
        f"{host}:{port}",
        "--automation-token",
        token,
        "--disable-crash-handler",
        "--log-file",
        str(log_file),
        "--quit-after",
        "0",
    ]
    # Keep stdout/stderr for post-mortem even if the engine also writes a log file.
    out_path = log_file.with_suffix(".stdout.txt")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_f = open(out_path, "wb")
    return subprocess.Popen(cmd, stdout=out_f, stderr=subprocess.STDOUT)


def main() -> int:
    ap = argparse.ArgumentParser(description="Autonomous VoxLand test suite runner (GPU stats + automation).")
    ap.add_argument("--config", default=str(Path(__file__).with_name("suite.json")))
    ap.add_argument("--engine", default="")
    ap.add_argument("--project", default="")
    ap.add_argument("--only", default="", help="Run only scenes whose name contains this substring.")
    ap.add_argument("--artifacts-dir", default="", help="Override artifacts output dir (default: runlogs/test_suite/<timestamp>).")
    args = ap.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass

    repo_root = Path(__file__).resolve().parents[2]
    cfg_path = Path(args.config).resolve()
    cfg = json.loads(cfg_path.read_text("utf-8"))

    engine = Path(args.engine) if args.engine else (repo_root / cfg.get("engine", "godot/engine-src/bin/godot.macos.editor.x86_64"))
    project_dir = Path(args.project) if args.project else (repo_root / cfg.get("project", "godot/project"))
    engine = engine.resolve()
    project_dir = project_dir.resolve()

    if not engine.exists():
        print(f"ERROR: engine binary not found: {engine}", file=sys.stderr)
        return 2
    if not (project_dir / "project.godot").exists():
        print(f"ERROR: project.godot not found under: {project_dir}", file=sys.stderr)
        return 2

    defaults = cfg.get("defaults", {}) or {}
    stats_every = int(defaults.get("stats_every", 10))
    startup_timeout_s = float(defaults.get("startup_timeout_s", 10.0))
    stats_timeout_s = float(defaults.get("stats_timeout_s", 10.0))

    timestamp = _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    artifacts_root = Path(args.artifacts_dir) if args.artifacts_dir else (repo_root / "runlogs" / "test_suite" / timestamp)
    artifacts_root.mkdir(parents=True, exist_ok=True)

    scenes = cfg.get("scenes", []) or []
    if args.only:
        scenes = [s for s in scenes if args.only.lower() in str(s.get("name", "")).lower()]
    if not scenes:
        print("No scenes selected.")
        return 0

    overall_ok = True
    results: List[Dict[str, Any]] = []

    for s in scenes:
        name = str(s.get("name") or "unnamed")
        scene_path = str(s.get("scene") or "")
        if not scene_path:
            print(f"[{name}] SKIP: missing scene path")
            overall_ok = False
            continue

        host = "127.0.0.1"
        port = _find_free_port(host)
        token = secrets.token_hex(8)

        scene_dir = artifacts_root / name
        scene_dir.mkdir(parents=True, exist_ok=True)
        log_file = scene_dir / "godot.log"

        proc = _launch_scene(engine, project_dir, scene_path, host, port, token, log_file)
        proc_ok = False
        baseline = None
        final = None
        failures: List[str] = []

        try:
            # Wait for server.
            cli = None
            deadline = time.time() + startup_timeout_s
            while time.time() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError(f"process exited early (code={proc.returncode})")
                try:
                    cli = AutomationClient(host, port, token)
                    break
                except Exception:
                    time.sleep(0.1)
            if cli is None:
                raise RuntimeError("automation server did not come up")

            try:
                _ = cli.call("ping").get("result")
                voxel_path, _orbit_path = _wait_for_voxel_renderer(cli, timeout_s=startup_timeout_s)

                # Configure renderer for stats and lower log noise.
                cli.call("set", {"path": voxel_path, "property": "debug_logging", "value": False})
                cli.call("set", {"path": voxel_path, "property": "diag_enabled", "value": False})
                cli.call("set", {"path": voxel_path, "property": "mpm_stats_enabled", "value": True})
                cli.call("set", {"path": voxel_path, "property": "mpm_stats_every", "value": int(s.get("stats_every", stats_every))})

                # Apply deterministic per-suite/per-scene overrides (so test outcomes don't depend on scene defaults).
                overrides: Dict[str, Any] = {}
                overrides.update(defaults.get("renderer_overrides", {}) or {})
                overrides.update(s.get("renderer_overrides", {}) or {})
                for prop, val in overrides.items():
                    cli.call("set", {"path": voxel_path, "property": prop, "value": val})

                reset_cfg = s.get("reset") or {}
                reset_name = str(reset_cfg.get("node_name") or "")
                reset_method = str(reset_cfg.get("method") or "")
                if reset_name and reset_method:
                    # Stop sim, reset the scenario, then start sim so baseline stats represent the intended initial condition.
                    cli.call("set", {"path": voxel_path, "property": "sim_enabled", "value": False})
                    dump = cli.call("dump_node_tree", {"path": "/root", "max_depth": 6, "max_children": 256}).get("result") or {}
                    reset_path = _find_first_path_by_name(dump, reset_name)
                    if not reset_path:
                        raise RuntimeError(f"could not find reset node by name={reset_name}")
                    cli.call("call", {"path": reset_path, "method": reset_method, "args": []})
                    cli.call("set", {"path": voxel_path, "property": "sim_enabled", "value": True})

                # First sample.
                frame0 = _wait_for_stats(cli, voxel_path, min_frame=0, timeout_s=stats_timeout_s)
                baseline = _fetch_stats(cli, voxel_path)
                (scene_dir / "stats_baseline.json").write_text(json.dumps(baseline, indent=2, sort_keys=True), "utf-8")

                # Run.
                run_duration_s = float(s.get("run_duration_s", defaults.get("run_duration_s", 6.0)))
                sample_points = s.get("sample_points_s", defaults.get("sample_points_s", [])) or []
                sample_points = [float(x) for x in sample_points]
                sample_points = sorted([x for x in sample_points if x > 0.0 and x < run_duration_s])

                start_t = time.time()
                next_frame = frame0
                timeline: List[Dict[str, Any]] = []
                for tpoint in sample_points + [run_duration_s]:
                    while True:
                        elapsed = time.time() - start_t
                        if elapsed >= tpoint:
                            break
                        if proc.poll() is not None:
                            raise RuntimeError(f"process exited early (code={proc.returncode})")
                        time.sleep(0.05)

                    # Ensure we advanced at least one stats frame since last read.
                    next_frame = _wait_for_stats(cli, voxel_path, min_frame=next_frame, timeout_s=stats_timeout_s)
                    sample = _fetch_stats(cli, voxel_path)
                    sample["t_s"] = float(tpoint)
                    timeline.append(sample)

                (scene_dir / "stats_timeline.json").write_text(json.dumps(timeline, indent=2, sort_keys=True), "utf-8")
                final = timeline[-1] if timeline else baseline
                (scene_dir / "stats_final.json").write_text(json.dumps(final, indent=2, sort_keys=True), "utf-8")

                # Screenshot for quick visual confirmation.
                shot_path = str((scene_dir / "screenshot.png").resolve())
                try:
                    cli.call("screenshot", {"path": shot_path})
                except Exception as e:
                    (scene_dir / "screenshot_error.txt").write_text(str(e), "utf-8")

                # Evaluate.
                proc_ok, failures = _eval_scene(s, baseline, final)
                overall_ok = overall_ok and proc_ok

                # Quit.
                try:
                    cli.call("quit")
                except Exception:
                    pass
            finally:
                if cli is not None:
                    cli.close()
        except Exception as e:
            overall_ok = False
            failures.append(str(e))
        finally:
            try:
                proc.wait(timeout=15.0)
            except Exception:
                try:
                    proc.terminate()
                    proc.wait(timeout=3.0)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
                except Exception:
                    pass
            # Avoid rapid-fire Vulkan device bring-up/tear-down between scenes on macOS.
            time.sleep(0.25)

        result = {
            "name": name,
            "scene": scene_path,
            "ok": proc_ok,
            "failures": failures,
        }
        results.append(result)

        status = "PASS" if proc_ok else "FAIL"
        print(f"[{name}] {status}")
        for f in failures:
            print(f"  - {f}")

        # Quick hints for common failure modes.
        if failures:
            hints: List[str] = []
            if any("nan_count" in f for f in failures):
                hints.append("NaNs: check g2p/p2g math and collision/clamping (often invalid mass or division by 0).")
            if any("overlap_static" in f for f in failures):
                hints.append("Static overlap: collision/constraints likely letting particles tunnel into static atlas.")
            if any("mass_loss" in f for f in failures):
                hints.append("Mass loss: particles may be getting deactivated, clamped out of bounds, or overwritten.")
            if hints:
                print("  Hints:")
                for h in hints:
                    print(f"  - {h}")

    (artifacts_root / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True), "utf-8")
    print(f"Artifacts: {artifacts_root}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
