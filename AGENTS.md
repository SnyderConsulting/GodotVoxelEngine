# AGENTS.md

## Purpose
Operational notes for agents working in this repository, especially around launching the app on macOS and finding key project areas quickly.

## macOS Launch Runbook

### Preferred interactive launch (stable)
Use the local engine app wrapper via macOS LaunchServices. This is the most reliable way to keep the GUI process alive:

```bash
cd /Users/andrewsnyder/AI-Projects/GodotVoxelEngine
open -n "$(pwd)/godot/engine-src/bin/godot_macos_editor.app" \
  --args \
  --path "$(pwd)/godot/project" \
  --scene res://scenes/ProtoHub.tscn \
  --disable-crash-handler
```

### Why this is needed
- Launching the raw binary from non-interactive shells can spawn briefly, then close.
- `open ... godot_macos_editor.app --args ...` keeps app lifecycle under LaunchServices so the window persists.

### If the app wrapper is broken (empty `.app` or missing executable)
Symptoms:
- `open` returns: "The application cannot be opened because its executable is missing."

Repair:

```bash
cd /Users/andrewsnyder/AI-Projects/GodotVoxelEngine
mkdir -p godot/engine-src/bin/godot_macos_editor.app/Contents/MacOS

cat > godot/engine-src/bin/godot_macos_editor.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GodotVoxelEditor</string>
  <key>CFBundleIdentifier</key><string>org.godotengine.voxeland.editor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>godot_macos_editor</string>
</dict>
</plist>
PLIST

cat > godot/engine-src/bin/godot_macos_editor.app/Contents/MacOS/godot_macos_editor <<'SH'
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/../../../godot.macos.editor.arm64" "$@"
SH

chmod +x godot/engine-src/bin/godot_macos_editor.app/Contents/MacOS/godot_macos_editor
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
- `godot/engine-src/bin/godot.macos.editor.arm64`: primary binary for Apple Silicon.
- `godot/engine-src/bin/godot.macos.editor.x86_64`: optional legacy Intel build (if present).
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
- For user-visible launches on macOS, prefer the `open ... godot_macos_editor.app --args ...` method above.
- In this repo, `ProtoHub` is the main menu scene used for interactive testing.
- If someone says "launch the app", use `ProtoHub` unless they request a specific scene.
