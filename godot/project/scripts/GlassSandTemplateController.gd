extends "res://scripts/BaseVoxelSceneController.gd"

@export var floor_thickness: int = 2
@export var edge_padding: int = 8
@export var table_rim_height: int = 3
@export var bowl_radius_ratio: float = 0.24
@export var bowl_wall_thickness: int = 2
@export var bowl_sand_height_ratio: float = 0.7
@export var cup_radius_ratio: float = 0.10
@export var cup_height_ratio: float = 0.38
@export var cup_wall_thickness: int = 2
@export var cup_sand_height_ratio: float = 0.7
@export var sand_density: float = 0.85
@export var sand_clearance: float = 0.6
@export var bowl_cup_gap_ratio: float = 0.08
@export var bowl_cup_gap_min: float = 6.0
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8

func _after_ready() -> void:
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(func ():
        _build_volume()
        renderer.gravity_dir = Vector3(0, -1, 0)
        _update_overlay()
    )

func _update_overlay() -> void:
    update_overlay_text(
        "Glass + Sand Template\n"
        + "Bowls/Cups on table, gravity/world sliders, Esc: hub."
    )

func _build_volume() -> void:
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center: float = (float(grid_extent) - 1.0) * 0.5
    var table_min: int = edge_padding
    var table_max: int = grid_extent - 1 - edge_padding
    var floor_y_max: int = max(1, floor_thickness)
    var bowl_radius: float = float(grid_extent) * bowl_radius_ratio
    var cup_radius: float = float(grid_extent) * cup_radius_ratio
    var cup_height: float = float(grid_extent) * cup_height_ratio
    var bowl_center := Vector3(float(grid_extent) * 0.35, float(floor_y_max) + bowl_radius, center)
    var cup_center := Vector3(float(grid_extent) * 0.65, float(floor_y_max) + cup_height * 0.5, center)
    var entries: Array = []

    for_each_bcc_cell(renderer, func(x: int, y: int, z: int, _extent: int) -> void:
        if x < table_min or x > table_max or z < table_min or z > table_max:
            return
        var is_floor: bool = y < floor_y_max
        var is_rim: bool = y >= floor_y_max and y < (floor_y_max + table_rim_height) and (
            x == table_min or x == table_max or z == table_min or z == table_max
        )
        var bowl_shell: bool = _is_bowl_shell(x, y, z, bowl_center, bowl_radius)
        var cup_shell: bool = _is_cup_shell(x, y, z, cup_center, cup_radius, cup_height)
        if is_floor or is_rim or bowl_shell or cup_shell:
            entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
            return
        if _in_bowl_sand(x, y, z, bowl_center, bowl_radius) or _in_cup_sand(x, y, z, cup_center, cup_radius, cup_height):
            if rng.randf() <= sand_density:
                entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})
    )

    renderer.set_voxel_entries(entries, true)

func _is_bowl_shell(x: int, y: int, z: int, bowl_center: Vector3, bowl_radius: float) -> bool:
    var dx := float(x) - bowl_center.x
    var dy := float(y) - bowl_center.y
    var dz := float(z) - bowl_center.z
    var r := sqrt(dx * dx + dz * dz)
    var shell_inner := bowl_radius - float(bowl_wall_thickness)
    var shell_outer := bowl_radius + sand_clearance
    return (r >= shell_inner and r <= shell_outer and dy <= 0.0)

func _in_bowl_sand(x: int, y: int, z: int, bowl_center: Vector3, bowl_radius: float) -> bool:
    var dx := float(x) - bowl_center.x
    var dy := float(y) - bowl_center.y
    var dz := float(z) - bowl_center.z
    if dy > 0.0:
        return false
    var r := sqrt(dx * dx + dz * dz)
    var height_limit := bowl_radius * bowl_sand_height_ratio
    return (r < (bowl_radius - sand_clearance) and absf(dy) <= height_limit)

func _is_cup_shell(x: int, y: int, z: int, cup_center: Vector3, cup_radius: float, cup_height: float) -> bool:
    var dx := float(x) - cup_center.x
    var dy := float(y) - cup_center.y
    var dz := float(z) - cup_center.z
    var r := sqrt(dx * dx + dz * dz)
    var shell_inner := cup_radius - float(cup_wall_thickness)
    var shell_outer := cup_radius + sand_clearance
    var within_height := absf(dy) <= (cup_height * 0.5)
    return within_height and r >= shell_inner and r <= shell_outer

func _in_cup_sand(x: int, y: int, z: int, cup_center: Vector3, cup_radius: float, cup_height: float) -> bool:
    var dx := float(x) - cup_center.x
    var dy := float(y) - cup_center.y
    var dz := float(z) - cup_center.z
    var r := sqrt(dx * dx + dz * dz)
    var height_limit := cup_height * cup_sand_height_ratio * 0.5
    return absf(dy) <= height_limit and r < (cup_radius - sand_clearance) and dy <= 0.0
