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

- A minimal `Main.tscn` with:
  - Camera orbit rig (mouse drag rotate, wheel zoom, optional pan).
  - Renderer node that owns GPU buffers and dispatches compute shaders.
  - Fullscreen texture output from the raymarch compute pass.

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

## Run

Launch the custom editor and open the project:

```powershell
godot\engine-bin\Godot_v4.5.1-stable_win64.exe --path godot\project
```

## Engine Automation (Custom Build)

This repo includes a custom Godot editor build with a TCP JSON automation server.

- Binary: `godot/engine-bin/Godot_v4.5.1-stable_win64.exe` (rebuilt from `godot/engine-src`)
- Start with automation enabled:

```powershell
godot\engine-bin\Godot_v4.5.1-stable_win64.exe --automation 127.0.0.1:24680 --automation-token yourtoken --path godot\project res://scenes/Main.tscn --disable-crash-handler
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

---

See `Voxel Physics Engine Deep Dive.md` for the full architectural background.
