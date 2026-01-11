# Glass + Sand Scene Template

This project has two working scene patterns (TumblerTest and HourglassTest) that
share a common scaffold. Use this guide to build a new scene with glass voxels,
sand voxels, and the gravity/world rotation control panel.

Renderer ownership note: scenes use the engine module `VoxelRenderer` (from `godot/engine-src/modules/voxels`). The project-side GPU shaders (`res://shaders/compute_*.glsl`) remain for reference but the live compute pipelines are in the engine module. The display shader `compute_display.gdshader` stays project-side.

## What the existing scenes share

TumblerTest and HourglassTest both use the same core components:

- OrbitRig (Node3D + `OrbitCamera.gd`) to drive the camera.
- Camera3D with a RaymarchQuad (QuadMesh + `compute_display.gdshader`).
- VoxelRenderer node (engine module class) that owns the GPU buffers.
- A scene controller script that fills voxel data on startup.
- HUD CanvasLayer with:
  - InfoLabel (overlay text).
  - Controls panel using `SceneControls.gd` for gravity + world rotation.

Patterns you will see in the controller scripts:

- Deferred initialization to wait for the renderer to be ready.
- A parity filter for the truncated-octahedron lattice:
  `if !((x & 1) == (y & 1) and (y & 1) == (z & 1))`.
- Building voxel entries on the CPU and calling:
  `set_voxel_entries(entries, true)` to allocate all bricks.
- Optional `Esc` handling to return to ProtoHub.

TumblerTest uses a simple glass box with sand fill. HourglassTest builds an
hourglass-shaped shell and pours sand through the neck, but the scene scaffold
is identical.

## Template scene (minimal)

A template scene and controller are provided here:

- `godot/project/scenes/GlassSandTemplate.tscn`
- `godot/project/scripts/GlassSandTemplateController.gd`

This is the smallest example that includes:

- Glass surface with a bowl and cup (material id 8).
- Sand fill inside the bowl and cup (material id 1).
- Gravity + world rotation sliders (SceneControls).
- Overlay label and Escape-to-hub behavior.

## How to create a new scene like the existing tests

1. Duplicate `godot/project/scenes/GlassSandTemplate.tscn` and rename the root.
2. Keep these required nodes and paths:
   - `OrbitRig/Camera3D/RaymarchQuad` (with `compute_display.gdshader`).
   - `VoxelRenderer` with `quad_path` and `camera_path` set.
   - `HUD/InfoLabel` for overlay text.
   - `HUD/Controls` using `SceneControls.gd` and its `voxel_renderer_path`.
3. Create a controller script similar to the template controller and assign it
   to a Node under the root. The controller should:
   - Wait for `VoxelRenderer.is_render_ready()`.
   - Build voxel entries with glass and sand.
   - Call `set_voxel_entries(entries, true)`.
4. Adjust `chunk_grid`, `chunk_size`, and orbit camera distance to fit your
   scene scale.

## Template geometry

The template builds:

- A flat glass surface (floor) with a low rim.
- A glass bowl (open hemisphere shell).
- A glass cup (open cylinder with a bottom).
- Sand voxels inside each container.

## Template build loop (bowl + cup)

This is the core loop used in the template controller:

```gdscript
var grid_extent: int = _renderer.chunk_grid * _renderer.chunk_size
var center: float = (float(grid_extent) - 1.0) * 0.5
var floor_y_max: int = max(1, floor_thickness)
var bowl_center := Vector3(float(grid_extent) * 0.35, float(floor_y_max) + bowl_radius, center)
var cup_center := Vector3(float(grid_extent) * 0.65, float(floor_y_max) + cup_height * 0.5, center)
var entries: Array = []

for z in range(grid_extent):
    for y in range(grid_extent):
        for x in range(grid_extent):
            if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                continue
    var in_table: bool = x >= table_min and x <= table_max and z >= table_min and z <= table_max
    if !in_table:
        continue
    var is_floor: bool = y < floor_y_max
    var is_rim: bool = y >= floor_y_max and y < (floor_y_max + rim_height) and (
        x == table_min or x == table_max or z == table_min or z == table_max
    )
            var bowl_shell: bool = _is_bowl_shell(x, y, z, bowl_center)
            var cup_shell: bool = _is_cup_shell(x, y, z, cup_center)
    if is_floor or is_rim or bowl_shell or cup_shell:
                entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
                continue
            if (_in_bowl_sand(x, y, z, bowl_center) or _in_cup_sand(x, y, z, cup_center)):
                if _rng.randf() <= sand_density:
                    entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})

_renderer.set_voxel_entries(entries, true)
```

The template script computes the bowl/cup math inline (no helper functions). See
`godot/project/scripts/GlassSandTemplateController.gd` for the full logic.

## Adding to ProtoHub

If you want the new scene to show up in the menu, add a button in
`godot/project/scenes/ProtoHub.tscn` and a matching `@export` + handler in
`godot/project/scripts/ProtoHub.gd`.
