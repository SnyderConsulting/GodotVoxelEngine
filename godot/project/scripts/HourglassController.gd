extends "res://scripts/BaseVoxelSceneController.gd"

@export var bulb_radius_ratio: float = 0.45
@export var neck_radius_ratio: float = 0.12
@export var wall_thickness: int = 2
@export var shell_padding: float = 0.45
@export var sand_clearance: float = 0.35
@export var sand_density: float = 0.85
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8

func _after_ready() -> void:
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(func _build_and_update):
        _build_hourglass()
        renderer.gravity_dir = Vector3(0, -1, 0)
        _update_overlay()

func _update_overlay() -> void:
    update_overlay_text(
        "Hourglass Test\n"
        + "Use sliders for gravity/world rotation | Esc: hub\n"
        + "Glass: outline only, sand falls through neck."
    )

func _build_hourglass() -> void:
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center: float = (float(grid_extent) - 1.0) * 0.5
    var half: float = maxf(center, 1.0)
    var bulb_radius: float = float(grid_extent) * bulb_radius_ratio
    var neck_radius: float = maxf(1.0, float(grid_extent) * neck_radius_ratio)
    var inner_wall: float = float(wall_thickness)
    var entries: Array = []

    for_each_bcc_cell(renderer, func(x: int, y: int, z: int, _extent: int) -> void:
        var dx: float = float(x) - center
        var dz: float = float(z) - center
        var r: float = sqrt(dx * dx + dz * dz)
        var t: float = absf(float(y) - center) / half
        var radius: float = lerp(neck_radius, bulb_radius, t)
        var cap := (y < wall_thickness) or (y >= grid_extent - wall_thickness)
        var shell_inner := radius - inner_wall
        var shell_outer := radius + shell_padding
        var shell := (r >= shell_inner and r <= shell_outer)
        if cap and r <= (bulb_radius + shell_padding):
            shell = true
        if shell:
            entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
            return
        var sand_limit := maxf(radius - inner_wall - sand_clearance, 0.0)
        if y > int(center + 1.0) and r < sand_limit:
            if rng.randf() <= sand_density:
                entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})
    )

    renderer.set_voxel_entries(entries, true)
