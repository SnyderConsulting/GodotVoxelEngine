# Voxel Sand GPU Demo

Proof-of-concept 3D voxel sand simulation using WebGPU compute shaders and a ray-marched renderer.

## Controls

- Click canvas to lock pointer
- WASD: move
- Space: jump
- Left Shift: sprint
- Mouse: look
- 1-8: select hotbar slot
- LMB: use item

## Run

This needs a local server for WebGPU.

```bash
python -m http.server
```

Open `http://localhost:8000/`.

## Current State

Working:
- 3D GPU sand simulation + ray-marched rendering
- FPS-style movement with 16-voxel player height
- Hotbar UI with selectable items
- Vacuum target sphere (fixed position) with pull behavior and inventory counting

Not Working / Known Issues:
- Vacuum pull behavior is inconsistent: some voxels jitter near the vacuum target instead of reliably disappearing
- Vacuum feels unstable under sustained use and needs deterministic resolution near the sink

## TODO

- Procedural world spawn system
- Player collision against voxel solids
- Stabilize vacuum sink behavior
