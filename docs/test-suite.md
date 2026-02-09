# VoxLand Dev/Test Suite

This repo includes a GPU-backed, autonomous test runner that launches key scenes via Godot's automation server, collects lightweight MPM stats from the GPU, captures screenshots, and evaluates pass/fail thresholds.

## Run

From repo root:

```bash
python3 godot/tests/run_suite.py
```

Run only a subset:

```bash
python3 godot/tests/run_suite.py --only hourglass
```

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

