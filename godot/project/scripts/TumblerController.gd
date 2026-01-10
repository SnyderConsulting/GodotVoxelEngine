extends "res://scripts/BaseVoxelSceneController.gd"

@export var fill_height_ratio: float = 0.55
@export var sand_density: float = 0.75
@export var wall_thickness: int = 1
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8

func _after_ready() -> void:
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(func _build_and_update):
        _build_tumbler()
        _update_overlay()

func _update_overlay() -> void:
    update_overlay_text(
        "Tumbler Test\n"
        + "Use the sliders for gravity and world rotation.\n"
        + format_gravity_world(renderer)
    )

func _build_tumbler() -> void:
    var entries: Array = []
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var min_wall := wall_thickness
    var max_wall := grid_extent - 1 - wall_thickness
    var fill_height := int(round(float(grid_extent) * fill_height_ratio))

    for_each_bcc_cell(renderer, func(x: int, y: int, z: int, _extent: int) -> void:
        var is_wall := (
            x < min_wall or x > max_wall
            or y < min_wall or y > max_wall
            or z < min_wall or z > max_wall
        )
        if is_wall:
            entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
            return
        if y <= fill_height and rng.randf() <= sand_density:
            entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})
    )

    renderer.set_voxel_entries(entries, true)
