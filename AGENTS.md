# AGENTS.md

## Purpose
Operational notes for agents working in this repository, especially around launching the app on macOS and finding key project areas quickly.

## macOS Launch Runbook

### Reliable interactive launch (works)
When launched from non-interactive/background shell contexts, Godot may run but no window appears.  
Use a real desktop Terminal session:

```bash
osascript <<'APPLESCRIPT'
tell application "Terminal"
  activate
  do script "cd /Users/andrewsnyder/AI-Projects/GodotVoxelEngine && /usr/local/bin/godot --path /Users/andrewsnyder/AI-Projects/GodotVoxelEngine/godot/project --scene res://scenes/ProtoHub.tscn --windowed --resolution 1280x720 --position 80,80"
end tell
APPLESCRIPT
```

### Standard direct launch command
Run from a local user shell:

```bash
cd /Users/andrewsnyder/AI-Projects/GodotVoxelEngine
/usr/local/bin/godot --path godot/project --scene res://scenes/ProtoHub.tscn
```

### Recording controls
- Toggle recording in app: `Cmd+Shift+R` (macOS)
- Optional startup recording arg: `-- --record-session <id>`
- Session output path: `runlogs/sessions/<session_id>/`

## Project Map

### Root
- `README.md`: high-level overview + basic launch notes.
- `docs/`: deeper documentation and run/build notes.
- `godot/`: engine source, project content, scripts/tests.
- `runlogs/`: session recordings and test-suite artifacts.
- `logs/`: assorted run logs.
- `references/`: external reference repos/docs.

### Runtime project (what you launch)
- `godot/project/project.godot`: project entry (`ProtoHub` main scene).
- `godot/project/scenes/`: gameplay/test scenes (e.g. `ProtoHub.tscn`, `PaintTest.tscn`).
- `godot/project/scripts/`: GDScript controllers and systems (`VoxelRenderer.gd`, `PaintController.gd`, `SessionRecorder.gd`, etc.).
- `godot/project/shaders/`: compute/render shaders (MPM + raymarch pipeline).
- `godot/project/data/`: voxel/material data JSONs.

### Engine build outputs
- `godot/engine-src/bin/godot.macos.editor.x86_64`: custom engine binary currently present.
- `godot/engine-src/bin/obj/`: object files/intermediates.

### Automation and tests
- `godot/tests/run_suite.py`: scene regression runner.
- `godot/tests/suite.json`: suite configuration.
- `godot/automation_client.py`: JSON-line automation client.

### Artifacts and debugging outputs
- `runlogs/sessions/`: per-session recorder output:
  - `meta.json`
  - `events.jsonl`
  - `mpm_stats.jsonl`
- `runlogs/test_suite/`: automated regression outputs per run/scene:
  - `results.json`
  - `stats_*.json`
  - `godot.log`
  - `screenshot.png`

## Practical Notes
- For user-visible app launches on macOS, prefer the Terminal AppleScript method above.
- In this repo, `ProtoHub` is the main menu scene used for interactive testing.
- If someone says "launch the app", use `ProtoHub` unless they request a specific scene.
