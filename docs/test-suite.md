# VoxLand Dev/Test Suite

This repo includes a GPU-backed, autonomous test runner that launches key scenes via Godot's automation server, collects lightweight MPM stats from the GPU, captures screenshots, and evaluates pass/fail thresholds.

The intention is not to unit test individual shaders, but to detect user-visible regressions early:
- Mass loss
- NaNs / instability
- Collisions leaking through glass/static solids
- Scenes that fail to settle or settle into the wrong place
- Rigid stability regressions (the classic MPM "jelly/melting" artifact)

## Run

From repo root:

```bash
python3 godot/tests/run_suite.py
```

Run only a subset:

```bash
python3 godot/tests/run_suite.py --only hourglass
```

Suite configuration lives in `godot/tests/suite.json`.

## Artifacts

Artifacts are written to:

`runlogs/test_suite/<timestamp>/<scene>/`

Each scene folder includes:

```text
godot.log
godot.stdout.txt
screenshot.png
stats_baseline.json
stats_timeline.json
stats_final.json
```

Suite-level summary:

`runlogs/test_suite/<timestamp>/results.json`

## Notes

- This test runner is not headless. It requires a real display/rendering driver so Vulkan compute can run.
- The GPU stats buffer is driven by `mpm_stats_init.glsl` + `mpm_stats.glsl` and surfaced through `VoxelRenderer.gd` automation-callable methods:
  - `mpm_get_last_stats_frame()`
  - `mpm_get_last_stats_raw()`
  - `mpm_get_last_stats()`

## What Gets Measured

Each stats sample includes:
- Per-material particle count and mass
- Average and max particle speed
- Per-material center of mass (COM)
- Per-material bounding box
- Count of particles overlapping static solids (by snapping to nearest BCC cell)
- NaN/Inf detection for position/velocity/mass
- Optional per-material column metrics (surface flatness) via `VoxelRenderer.mpm_get_material_column_metrics(mat_id)`

The runner compares a baseline sample (right after startup/reset) to a final sample after `run_duration_s`.

## Additional Checks (Suite JSON)

`material_checks[]` supports extra keys for behavioral assertions:
- `column_var_final_max`, `column_range_final_max`, `column_var_max`, `column_range_max`
  - Require `mpm_get_material_column_metrics()` and catch water "piling" regressions (water behaving like sand).
- `bbox_min_x_min/max`, `bbox_min_y_min/max`, `bbox_min_z_min/max`, `bbox_max_x_min/max`, `bbox_max_y_min/max`, `bbox_max_z_min/max`
  - Constrain final bounding box per material (useful for impermeability tests, e.g. water staying above a static sand bed).

## Per-Scene Overrides And Reset Hooks

The runner can override `VoxelRenderer` properties per scene via `renderer_overrides` (for determinism).

Some scenes also specify a `reset` hook:
- Temporarily sets `VoxelRenderer.sim_enabled=false`
- Calls a controller method (example: `JellyController._build_scene`)
- Re-enables sim

This makes baseline stats correspond to the intended initial condition, not whatever the scene happened to do before automation connected.

## Common Failure Modes (And What They Usually Mean)

### Jelly Test "Explodes" (Stone Speeds Pegged Near Clamp)

Symptoms:
- Baseline or early timeline shows very high stone velocities (often near the hard clamp, ~`120`)
- Stone COM can drift upward despite gravity being overridden to `0.0`

Most common root cause:
- GPU buffer out-of-bounds due to a dispatch size mismatch.

Concrete example we already hit:
- `mpm_island_finalize.glsl` is `local_size_x=256` and has no bounds check.
- If the island SSBOs are allocated to exactly `max_particles+1` elements but the dispatch rounds up to the next 256 multiple, the finalize stage will read/write past the end, corrupting adjacent buffers and destabilizing the entire sim.

Mitigation:
- Pad the island buffers to `ceil(island_count/256)*256` elements, or add an explicit bounds check (requires passing island_count into the shader).

### Baseline Stats Already Show Motion

This usually means the scenario started simulating before the runner applied overrides/reset.
Use a `reset` hook and/or ensure scenes start with `sim_enabled=false` until the controller sets initial state.
