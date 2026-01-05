# Raymarching Notes (Godot)

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

## References
- Raymarching intro tutorial: https://www.youtube.com/watch?v=68G3V5Yr8FY
