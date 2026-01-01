# Voxel Sand GPU Demo

Proof-of-concept 3D voxel sand simulation using WebGPU compute shaders and a ray-marched renderer.

## Controls

- Click canvas to lock pointer
- WASD: move
- Space / Left Shift: up / down
- Mouse: look
- LMB: add sand
- RMB: erase sand

## Run

This needs a local server for WebGPU.

```bash
python -m http.server
```

Open `http://localhost:8000/`.
