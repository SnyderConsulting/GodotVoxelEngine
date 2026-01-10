# Raymarching Notes (Godot)

> Note: The active raymarch compute now lives in the engine module (`godot/engine-src/modules/voxels/compute_raymarch.glsl`). Project-side compute shaders remain for reference/legacy. The display shader (`res://shaders/compute_display.gdshader`) is still project-side.

## Why the screen was solid gray
- The shader failed to compile, so the material did not render.
- `CAMERA_POSITION` is not a valid identifier in Godot 4 spatial shaders.
- `INV_MODEL_MATRIX` is also not a valid identifier in this shader stage.
- Using `return` inside `fragment()` is not allowed in Godot shaders.

## Working camera origin in shader
- To get the camera position in world space inside `fragment()`:
  - `vec3 cam_world = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;`
- Convert that to local space with:
  - `vec3 ro = (inverse(MODEL_MATRIX) * vec4(cam_world, 1.0)).xyz;`

## Material application
- `MeshInstance3D.material_override` sets a single material for all surfaces.
- This is implemented in engine source:
  - `godot/engine-src/scene/3d/visual_instance_3d.cpp` (`GeometryInstance3D::set_material_override`).
  - `godot/engine-src/doc/classes/MeshInstance3D.xml` describes the override priority.

## Minimal validation pattern
- Add a debug uniform to force a flat color (to prove the shader is running).
- Use engine logs to catch shader compile errors:
  - `C:\Users\andre\AppData\Roaming\Godot\app_userdata\VoxLand\logs\godot.log`  

## Voxel raymarch traversal cap (missing pieces at some angles)
- Symptom: voxels partially disappeared when the camera was rotated to certain yaw/pitch values.
- Root cause: the empty-space march used a fixed `0.01` step with `2048` steps, so rays could only travel ~20.48 world units and never reached the voxel cluster on diagonals.
- Fix: in `godot/project/shaders/compute_raymarch.glsl`, raise the loop to `MAX_STEPS = 4096` and compute an adaptive `empty_step = max(0.01 * voxel_size, (t_exit - t) / MAX_STEPS)` so the ray always spans the grid bounds.

## Brickmap hierarchical traversal (chunk-skip DDA)
- Added a brick-level DDA over the occupancy grid in `godot/project/shaders/compute_raymarch.glsl` to skip empty bricks and only do fine SDF marching inside occupied chunks.
- Neighbor bricks are treated as active to avoid clipping truncated-octahedron voxels that straddle brick boundaries.

## Simple flood-fill lighting
- Added `godot/project/shaders/compute_light.glsl` to propagate Minecraft-style light through empty BCC cells (sunlight from the top layer).
- Raymarching samples the light buffer (plus neighbor max) to modulate ambient and diffuse terms.

## References
- Raymarching intro tutorial: https://www.youtube.com/watch?v=68G3V5Yr8FY
