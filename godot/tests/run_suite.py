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

_GODOT_ROOT = Path(__file__).resolve().parents[1]
if str(_GODOT_ROOT) not in sys.path:
    sys.path.insert(0, str(_GODOT_ROOT))

from automation_rpc import AutomationClient

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


def _resolve_engine_path(repo_root: Path, configured_path: str) -> Path:
    first = (repo_root / configured_path).resolve()
    candidates: List[Path] = [first]
    if sys.platform == "darwin":
        arm64 = (repo_root / "godot/engine-src/bin/godot.macos.editor.arm64").resolve()
        x64 = (repo_root / "godot/engine-src/bin/godot.macos.editor.x86_64").resolve()
        if first.name.endswith(".arm64"):
            candidates.append(x64)
        elif first.name.endswith(".x86_64"):
            candidates.append(arm64)
        else:
            candidates.extend([arm64, x64])
    seen: set = set()
    for c in candidates:
        key = str(c)
        if key in seen:
            continue
        seen.add(key)
        if c.exists():
            return c
    return first


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


def _audit_global(audit: Dict[str, Any]) -> Dict[str, Any]:
    g = audit.get("global") or {}
    return g if isinstance(g, dict) else {}


def _audit_mat(audit: Dict[str, Any], mat_id: int) -> Dict[str, Any]:
    mats = audit.get("materials") or []
    if isinstance(mats, list):
        if 0 <= mat_id < len(mats):
            m = mats[mat_id]
            if isinstance(m, dict):
                return m
        for m in mats:
            if isinstance(m, dict) and int(m.get("mat_id", -1)) == mat_id:
                return m
    return {"mat_id": mat_id}


def _label_sample(sample: Dict[str, Any]) -> str:
    if "t_s" in sample:
        return f"t={float(sample.get('t_s') or 0.0):.2f}s"
    return "baseline"


def _column_metrics(sample: Dict[str, Any], mat_id: int) -> Dict[str, Any]:
    cms = sample.get("column_metrics") or []
    if isinstance(cms, list):
        for m in cms:
            if isinstance(m, dict) and int(m.get("mat_id", -1)) == mat_id:
                return m
    return {"mat_id": mat_id}


def _eval_scene(
    scene_cfg: Dict[str, Any],
    baseline: Dict[str, Any],
    final: Dict[str, Any],
    timeline: List[Dict[str, Any]],
) -> Tuple[bool, List[str]]:
    failures: List[str] = []
    defaults = scene_cfg.get("_defaults", {}) or {}

    checks: Dict[str, Any] = {}
    checks.update(defaults.get("checks", {}) or {})
    checks.update(scene_cfg.get("checks", {}) or {})

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

    # Discrete voxel invariants: no per-cell duplicates (prevents "voxel compression"),
    # and no render-cell spill (prevents flicker/teleport due to voxelization contention).
    discrete_checks: Dict[str, Any] = {}
    discrete_checks.update(defaults.get("discrete_checks", {}) or {})
    discrete_checks.update(scene_cfg.get("discrete_checks", {}) or {})

    discrete_material_defaults: Dict[str, Any] = {}
    discrete_material_defaults.update(defaults.get("discrete_material_defaults", {}) or {})
    discrete_material_defaults.update(scene_cfg.get("discrete_material_defaults", {}) or {})

    samples = [baseline] + (timeline or [])
    if discrete_checks:
        for s in samples:
            audit = s.get("discrete_audit") or {}
            if not isinstance(audit, dict) or not audit:
                failures.append(f"{_label_sample(s)} missing discrete_audit")
                continue
            g = _audit_global(audit)

            if "global_dupes_max" in discrete_checks:
                maxv = int(discrete_checks["global_dupes_max"])
                v = int(g.get("dupes", 0))
                if v > maxv:
                    failures.append(f"{_label_sample(s)} global_dupes {v} > {maxv}")

            if "global_max_per_cell_max" in discrete_checks:
                maxv = int(discrete_checks["global_max_per_cell_max"])
                v = int(g.get("max_per_cell", 0))
                if v > maxv:
                    failures.append(f"{_label_sample(s)} global_max_per_cell {v} > {maxv}")

            if "global_render_mismatched_max" in discrete_checks:
                maxv = int(discrete_checks["global_render_mismatched_max"])
                v = int(g.get("render_mismatched", 0))
                if v > maxv:
                    failures.append(f"{_label_sample(s)} global_render_mismatched {v} > {maxv}")

            if "global_mapped_frac_min" in discrete_checks:
                minv = float(discrete_checks["global_mapped_frac_min"])
                active = int(audit.get("active_particles", 0))
                mapped = int(g.get("mapped", 0))
                frac = (float(mapped) / float(active)) if active > 0 else 1.0
                if frac < minv:
                    failures.append(f"{_label_sample(s)} global_mapped_frac {frac:.3f} < {minv:.3f}")

    mat_checks = scene_cfg.get("material_checks", []) or []
    for mc in mat_checks:
        mat_id = int(mc.get("mat_id", -1))
        if mat_id < 0:
            continue
        b = _slot(baseline, mat_id)
        f = _slot(final, mat_id)
        samples = [baseline] + (timeline or [])

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

        if "count_loss_frac_max" in mc:
            frac_max = float(mc["count_loss_frac_max"])
            bc = float(b.get("count", 0))
            fc = float(f.get("count", 0))
            if bc > 0.0:
                loss_frac = max(0.0, (bc - fc) / bc)
                if loss_frac > frac_max:
                    failures.append(f"mat={mat_id} count_loss_frac {loss_frac:.4f} > {frac_max:.4f}")

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

        # Column metrics checks (surface flatness). These require VoxelRenderer.mpm_get_material_column_metrics().
        # - Water should level out: low variance/range.
        # - Sand should generally *not* be constrained by these checks unless explicitly configured.
        if any(k.startswith("column_") for k in mc.keys()):
            cm_final = _column_metrics(final, mat_id)
            if not isinstance(cm_final, dict) or "columns" not in cm_final:
                failures.append(f"mat={mat_id} missing column_metrics in final sample")
            else:
                if "column_var_final_max" in mc:
                    vmax = float(mc["column_var_final_max"])
                    v = float(cm_final.get("var_h", 0.0))
                    if v > vmax:
                        failures.append(f"mat={mat_id} column_var_final {v:.3f} > {vmax:.3f}")
                if "column_range_final_max" in mc:
                    rmax = float(mc["column_range_final_max"])
                    r = float(cm_final.get("range_h", 0.0))
                    if r > rmax:
                        failures.append(f"mat={mat_id} column_range_final {r:.1f} > {rmax:.1f}")

            # Optional: enforce a max across the entire timeline (baseline + samples).
            if "column_var_max" in mc:
                vmax = float(mc["column_var_max"])
                worst = 0.0
                ok_any = False
                for s in samples:
                    cm = _column_metrics(s, mat_id)
                    if isinstance(cm, dict) and "columns" in cm:
                        ok_any = True
                        worst = max(worst, float(cm.get("var_h", 0.0)))
                if not ok_any:
                    failures.append(f"mat={mat_id} missing column_metrics for timeline")
                elif worst > vmax:
                    failures.append(f"mat={mat_id} column_var_max {worst:.3f} > {vmax:.3f}")

            if "column_range_max" in mc:
                rmax = float(mc["column_range_max"])
                worst = 0.0
                ok_any = False
                for s in samples:
                    cm = _column_metrics(s, mat_id)
                    if isinstance(cm, dict) and "columns" in cm:
                        ok_any = True
                        worst = max(worst, float(cm.get("range_h", 0.0)))
                if not ok_any:
                    failures.append(f"mat={mat_id} missing column_metrics for timeline")
                elif worst > rmax:
                    failures.append(f"mat={mat_id} column_range_max {worst:.1f} > {rmax:.1f}")

        # Per-material bounding-box constraints (final sample only).
        # Keys: bbox_min_<axis>_min/max, bbox_max_<axis>_min/max where axis in {x,y,z}.
        if any(k.startswith("bbox_") for k in mc.keys()):
            if not bool(f.get("bbox_valid", False)):
                failures.append(f"mat={mat_id} missing/invalid bbox in final sample")
            else:
                bmin = f.get("bbox_min") or (0.0, 0.0, 0.0)
                bmax = f.get("bbox_max") or (0.0, 0.0, 0.0)
                try:
                    bmin = (float(bmin[0]), float(bmin[1]), float(bmin[2]))
                    bmax = (float(bmax[0]), float(bmax[1]), float(bmax[2]))
                except Exception:
                    bmin = (0.0, 0.0, 0.0)
                    bmax = (0.0, 0.0, 0.0)
                axis_idx = {"x": 0, "y": 1, "z": 2}
                for axis, ai in axis_idx.items():
                    k = f"bbox_min_{axis}_min"
                    if k in mc:
                        vmin = float(mc[k])
                        vv = float(bmin[ai])
                        if vv < vmin:
                            failures.append(f"mat={mat_id} {k} {vv:.3f} < {vmin:.3f}")
                    k = f"bbox_min_{axis}_max"
                    if k in mc:
                        vmax = float(mc[k])
                        vv = float(bmin[ai])
                        if vv > vmax:
                            failures.append(f"mat={mat_id} {k} {vv:.3f} > {vmax:.3f}")
                    k = f"bbox_max_{axis}_min"
                    if k in mc:
                        vmin = float(mc[k])
                        vv = float(bmax[ai])
                        if vv < vmin:
                            failures.append(f"mat={mat_id} {k} {vv:.3f} < {vmin:.3f}")
                    k = f"bbox_max_{axis}_max"
                    if k in mc:
                        vmax = float(mc[k])
                        vv = float(bmax[ai])
                        if vv > vmax:
                            failures.append(f"mat={mat_id} {k} {vv:.3f} > {vmax:.3f}")

        # Per-material discrete checks are evaluated across all samples (baseline + timeline),
        # because a transient violation is still a visible artifact.
        eff_discrete_mc: Dict[str, Any] = {}
        eff_discrete_mc.update(discrete_material_defaults)
        # Allow both styles:
        # - material_checks[]: { ..., "discrete": { ... } }
        # - material_checks[]: { ..., "discrete_dupes_max": 0, ... }
        eff_discrete_mc.update(mc.get("discrete", {}) or {})
        for k, v in mc.items():
            if k.startswith("discrete_"):
                eff_discrete_mc[k[len("discrete_") :]] = v

        if eff_discrete_mc:
            for s in samples:
                audit = s.get("discrete_audit") or {}
                if not isinstance(audit, dict) or not audit:
                    continue
                m = _audit_mat(audit, mat_id)
                label = _label_sample(s)

                if "dupes_max" in eff_discrete_mc:
                    maxv = int(eff_discrete_mc["dupes_max"])
                    vv = int(m.get("dupes", 0))
                    if vv > maxv:
                        failures.append(f"{label} mat={mat_id} dupes {vv} > {maxv}")

                if "max_per_cell_max" in eff_discrete_mc:
                    maxv = int(eff_discrete_mc["max_per_cell_max"])
                    vv = int(m.get("max_per_cell", 0))
                    if vv > maxv:
                        failures.append(f"{label} mat={mat_id} max_per_cell {vv} > {maxv}")

                if "render_mismatched_max" in eff_discrete_mc:
                    maxv = int(eff_discrete_mc["render_mismatched_max"])
                    vv = int(m.get("render_mismatched", 0))
                    if vv > maxv:
                        failures.append(f"{label} mat={mat_id} render_mismatched {vv} > {maxv}")

                if "mapped_frac_min" in eff_discrete_mc:
                    minv = float(eff_discrete_mc["mapped_frac_min"])
                    c = int(m.get("count", 0))
                    mapped = int(m.get("mapped", 0))
                    frac = (float(mapped) / float(c)) if c > 0 else 1.0
                    if frac < minv:
                        failures.append(f"{label} mat={mat_id} mapped_frac {frac:.3f} < {minv:.3f}")

                if "avg_spill_max" in eff_discrete_mc:
                    maxv = float(eff_discrete_mc["avg_spill_max"])
                    vv = float(m.get("avg_spill", 0.0))
                    if vv > maxv:
                        failures.append(f"{label} mat={mat_id} avg_spill {vv:.4f} > {maxv:.4f}")

                if "max_spill_max" in eff_discrete_mc:
                    maxv = float(eff_discrete_mc["max_spill_max"])
                    vv = float(m.get("max_spill", 0.0))
                    if vv > maxv:
                        failures.append(f"{label} mat={mat_id} max_spill {vv:.4f} > {maxv:.4f}")

    return (len(failures) == 0), failures


def _required_column_materials(scene_cfg: Dict[str, Any]) -> List[int]:
    mats: List[int] = []
    # Explicit allow-list.
    for x in scene_cfg.get("column_metrics", []) or []:
        try:
            mats.append(int(x))
        except Exception:
            pass
    # Implicit from material checks.
    for mc in scene_cfg.get("material_checks", []) or []:
        if not isinstance(mc, dict):
            continue
        if not any(str(k).startswith("column_") for k in mc.keys()):
            continue
        try:
            mid = int(mc.get("mat_id", -1))
        except Exception:
            mid = -1
        if mid >= 0:
            mats.append(mid)
    # De-dup while preserving order.
    out: List[int] = []
    seen = set()
    for m in mats:
        if m in seen:
            continue
        seen.add(m)
        out.append(m)
    return out


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


def _request_discrete_audit(cli: AutomationClient, voxel_path: str) -> int:
    resp = cli.call("call", {"path": voxel_path, "method": "mpm_request_discrete_audit", "args": []})
    return int(resp.get("result") or 0)


def _wait_for_discrete_audit(cli: AutomationClient, voxel_path: str, req_id: int, timeout_s: float) -> None:
    if req_id <= 0:
        raise RuntimeError(f"invalid discrete audit request id: {req_id}")
    deadline = time.time() + timeout_s
    last = -1
    while time.time() < deadline:
        resp = cli.call("call", {"path": voxel_path, "method": "mpm_get_last_discrete_audit_frame", "args": []})
        frame = int(resp.get("result") or 0)
        last = frame
        if frame >= req_id:
            return
        time.sleep(0.05)
    raise RuntimeError(f"discrete audit did not complete (req={req_id} last={last})")


def _fetch_discrete_audit(cli: AutomationClient, voxel_path: str) -> Dict[str, Any]:
    audit = cli.call("call", {"path": voxel_path, "method": "mpm_get_last_discrete_audit", "args": []}).get("result")
    if not isinstance(audit, dict):
        raise RuntimeError(f"unexpected discrete audit type: {type(audit)}")
    return audit


def _fetch_column_metrics(cli: AutomationClient, voxel_path: str, mat_ids: List[int]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for mid in mat_ids:
        try:
            resp = cli.call("call", {"path": voxel_path, "method": "mpm_get_material_column_metrics", "args": [int(mid)]})
            cm = resp.get("result")
            if not isinstance(cm, dict):
                out.append({"mat_id": int(mid), "error": f"unexpected column metrics type: {type(cm)}"})
                continue
            out.append(cm)
        except Exception as e:
            out.append({"mat_id": int(mid), "error": str(e)})
    return out


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

    if args.engine:
        engine = Path(args.engine)
    else:
        cfg_engine = str(cfg.get("engine", "godot/engine-src/bin/godot.macos.editor.x86_64"))
        engine = _resolve_engine_path(repo_root, cfg_engine)
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

        # Merge per-scene checks with defaults (so suite.json doesn't need to repeat boilerplate).
        scene_cfg: Dict[str, Any] = dict(s)
        scene_cfg["_defaults"] = defaults

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
                    cli = AutomationClient(
                        host,
                        port,
                        token,
                        connect_timeout_s=2.0,
                        call_timeout_s=30.0,
                        call_retries=1,
                        retry_delay_s=0.1,
                    )
                    break
                except Exception:
                    time.sleep(0.1)
            if cli is None:
                raise RuntimeError("automation server did not come up")

            try:
                _ = cli.call("ping").get("result")
                voxel_path, _orbit_path = _wait_for_voxel_renderer(cli, timeout_s=startup_timeout_s)
                column_mats = _required_column_materials(scene_cfg)

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
                try:
                    req = _request_discrete_audit(cli, voxel_path)
                    _wait_for_discrete_audit(cli, voxel_path, req, timeout_s=stats_timeout_s)
                    baseline["discrete_audit"] = _fetch_discrete_audit(cli, voxel_path)
                except Exception as e:
                    baseline["discrete_audit_error"] = str(e)
                if column_mats:
                    baseline["column_metrics"] = _fetch_column_metrics(cli, voxel_path, column_mats)
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
                    try:
                        req = _request_discrete_audit(cli, voxel_path)
                        _wait_for_discrete_audit(cli, voxel_path, req, timeout_s=stats_timeout_s)
                        sample["discrete_audit"] = _fetch_discrete_audit(cli, voxel_path)
                    except Exception as e:
                        sample["discrete_audit_error"] = str(e)
                    if column_mats:
                        sample["column_metrics"] = _fetch_column_metrics(cli, voxel_path, column_mats)
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
                proc_ok, failures = _eval_scene(scene_cfg, baseline, final, timeline)
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
