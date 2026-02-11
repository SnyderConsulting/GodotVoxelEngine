# MPM Debug Log - February 11, 2026

## Scope
- Scenes: `PaintTest` and world-rotation/tumbler-style gravity changes.
- Focus: sand/water responsiveness, wall sticking, spray/explosive motion, and automation-first validation.

## Issues Found and Fixed
1. **Automation could not reliably spawn/delete/query voxels at runtime**
- Symptom: automation calls returned zero/partial spawn behavior due to type mismatch.
- Root cause: runtime APIs expected typed `Vector3i` arrays; automation sent JSON arrays.
- Fix:
  - Added coercion helpers and automation wrappers in `godot/project/scripts/VoxelRenderer.gd`:
    - `automation_spawn_cells`
    - `automation_set_voxels`
    - `automation_get_cell_materials`
    - `automation_reset_empty`
  - Added `mpm_get_particle_snapshot` for per-particle/contact metrics.

2. **Sand and water could appear glued to glass/walls after gravity direction changes**
- Symptom: side-wall particles remained slow/stuck and took too long to settle.
- Root cause: contact friction removed too much tangential motion, including gravity-aligned slide.
- Fix:
  - Added gravity-aware contact friction in `godot/project/shaders/mpm_g2p_advect.glsl`:
    - `gravity_dir_norm()`
    - `apply_contact_friction()`
  - Reduced sand friction coefficients and tuned damping/sleep logic for side-wall cases.

3. **Sand could show high-velocity outliers ("exploding"/jittery motion)**
- Symptom: some particles had persistent very high speed under contact-heavy motion.
- Root cause: collision/blocked-cell cycles could preserve too much residual energy.
- Fix:
  - Added sand speed safety caps (pre/post collision blocks).
  - Tightened blocked-cell handling and low-speed sleep behavior.

4. **Sand could scatter laterally too aggressively on spawn/settling**
- Symptom: sprayed dispersion pattern during contention, inconsistent with natural pile collapse.
- Root cause: random fallback neighbor claims during discrete relocation.
- Fix:
  - Replaced sand fallback with gravity-biased deterministic multi-attempt neighbor selection.
  - Added small per-particle jitter in tie-break scoring so behavior is not perfectly uniform.

5. **Tall columns could stall instead of collapsing**
- Symptom: columns stayed elevated and looked "lazy."
- Root cause: under contention, particles lost downward progress when local claims failed.
- Fix:
  - Lowered sand transport threshold (`transport_speed`) to trigger movement sooner.
  - Preserved a small gravity-aligned velocity when blocked to keep collapse progressing.
  - Retained anti-explosion caps to avoid regressions.

## Validation Method and Key Results
- Added automation harness: `godot/automation_runtime_lab.py` (scenario: `paint_lab`).
- Used direct runtime commands (`set`, `call`) plus metrics:
  - `mpm_get_last_stats_raw`
  - `mpm_get_material_column_metrics`
  - `mpm_request_discrete_audit` / `mpm_get_last_discrete_audit`
  - `mpm_get_particle_snapshot`

Notable measured improvements:
- Hold-phase sand peak speed reduced from `12.467` to `8.0` in paint-lab stress checks.
- Wall-adjacent slow/stuck contact ratio dropped substantially in hold phases.
- Tall-column collapse now progresses rapidly (mean column height collapses near floor range in ~1-2 seconds in automation probes).
- Lateral movement now shows mixed direction bins (not a single uniform lane), while remaining gravity-biased.

## Operational Notes
- For repeatable metric runs:
  - launch `PaintTest` with automation:
    - `godot/engine-src/bin/godot.macos.editor.x86_64 --path godot/project --scene res://scenes/PaintTest.tscn --automation 127.0.0.1:24682 --automation-token voxdebug`
  - run:
    - `python3 godot/automation_runtime_lab.py --host 127.0.0.1 --port 24682 --token voxdebug --scenario paint_lab --outdir runlogs/manual_debug/<name>`
