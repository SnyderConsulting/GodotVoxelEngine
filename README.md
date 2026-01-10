# VoxLand (Godot GPU Voxel Reset)

This project is a clean restart focused on a single GPU-resident voxel volume rendered in Godot via compute shaders, following the architecture outlined in `Voxel Physics Engine Deep Dive.md`.

## Goal

- Render a truncated-octahedron voxel lattice volume entirely on the GPU.
- Use a brickmap + indirection buffer for sparse storage (GPU tiling only).
- Provide a 360-degree isometric-style view with orbit/zoom controls.
- Keep simulation optional; the initial focus is on rendering and camera control.

## Planned Architecture

- **GPU-resident state**: voxel data stays in VRAM; CPU only uploads initial data and optional debug readbacks.
- **Brickmap layout**:
  - Indirection buffer maps brick coords to atlas indices.
  - Atlas buffer stores voxel material/flags per brick.
  - Occupancy buffer flags non-empty bricks to accelerate traversal.
- **Compute shaders**:
  - Occupancy pass (brick-level occupied flags).
  - Raymarch pass (screen-space render into a texture).
  - Optional sim passes later (active list + indirect args + ping-pong buffers).

## Scene Overview

- `ProtoHub.tscn` is the launch menu for the current test scenes.
- `TumblerTest.tscn` and `HourglassTest.tscn` each pair the orbit camera with
  the voxel renderer and a fullscreen raymarch quad.

## Controls (Target)

- LMB drag: orbit camera
- Mouse wheel: zoom
- Shift + LMB drag: pan (optional)
- F1: toggle debug overlay (occupancy/normal pass)

## Development Notes

- Voxel volume size: determined by `chunk_grid * chunk_size` (lattice cells).
- Brick size: 8 cells per brick (GPU tiling only, not spatial alignment).
- Lattice: truncated-octahedron tessellation defines voxel adjacency and placement.
- Start with a simple voxel fill pattern (solid cube core or checker layers).

## Project Layout

- `godot/engine-src`: Godot engine source (custom automation changes).
- `godot/engine-bin`: Rebuilt editor binaries.
- `godot/project`: Fresh Godot project scaffold (currently minimal scene).

## Run / Build

- Engine voxel renderer lives in `godot/engine-src/modules/voxels`; keep that module present for any rebuild.
- After each `scons` build, copy the template_debug binaries from `godot/engine-src/bin/` into `godot/engine-bin/` with the expected names (`Godot_v4.5.1-automation-dev_win64{.console}.exe`).
- See `docs/build-and-launch.md` for the exact build command, copy steps, and launch options.

Launch the custom editor and open the project:

```powershell
godot\run_editor_dev.ps1
```

## Engine Automation (Custom Build)

This repo includes a custom Godot build with a TCP JSON automation server.

- Binary: `godot/engine-bin/Godot_v4.5.1-automation-dev_win64.exe` (rebuilt from `godot/engine-src`)
- Start with automation enabled:

```powershell
godot\run_automation_dev.ps1 -AutomationToken yourtoken
```

### Automation Protocol (JSON lines)

Each request/response is a single JSON line. Token auth is required if provided.

Supported methods:
- `auth`, `ping`
- `get_node`, `list_children`
- `call`, `get`, `set`
- `action_press`, `action_release`
- `screenshot`, `get_fps`, `quit`

Example (PowerShell client):
```powershell
godot\automation_client.ps1 -ServerHost 127.0.0.1 -Port 24680 -Token yourtoken -Method ping
godot\automation_client.ps1 -ServerHost 127.0.0.1 -Port 24680 -Token yourtoken -Method screenshot -ParamsJson '{\"path\":\"user://snap.png\"}'
```

### Automation Probes (Voxel Renderer)

Use the probe runner to step the orbit rig and update the VoxelRenderer probe cell while logging:

```powershell
godot\automation_probe_voxels.ps1 -Token yourtoken -Steps 24 -ProbeStride 1 -SleepMs 200
```

---

See `Voxel Physics Engine Deep Dive.md` for the full architectural background.
