extends Node

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
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
@export var random_seed: int = 2026

var _renderer: Node = null
var _overlay: Label = null
var _rng := RandomNumberGenerator.new()
var _init_attempts: int = 0

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _overlay = get_node_or_null(overlay_path) as Label
    if _renderer == null:
        push_error("GlassSandTemplateController missing VoxelRenderer.")
        return
    _rng.seed = random_seed
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    if !_wait_for_renderer_ready():
        return
    _build_volume()
    _renderer.gravity_dir = Vector3(0, -1, 0)
    _update_overlay()

func _wait_for_renderer_ready() -> bool:
    if _renderer == null:
        return false
    if _renderer.has_method("is_render_ready") and !_renderer.is_render_ready():
        _init_attempts += 1
        if _init_attempts <= 120:
            call_deferred("_initialize_scenario")
        else:
            push_error("GlassSandTemplateController renderer not ready.")
        return false
    return true

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return
    _update_overlay()

func _update_overlay() -> void:
    if _overlay == null:
        return
    var gravity = _renderer.gravity_dir
    var world_rot = _renderer.world_rotation * 180.0 / PI
    _overlay.text = (
        "Glass Surface + Bowl + Cup\n"
        + "Use the sliders for gravity and world rotation.\n"
        + "World Rot deg: (%.1f, %.1f, %.1f)\n"
        + "Gravity: (%.2f, %.2f, %.2f)"
    ) % [world_rot.x, world_rot.y, world_rot.z, gravity.x, gravity.y, gravity.z]

func _build_volume() -> void:
    var grid_extent: int = _renderer.chunk_grid * _renderer.chunk_size
    var center: float = (float(grid_extent) - 1.0) * 0.5
    var floor_y_max: int = max(1, floor_thickness)
    var pad: int = max(0, edge_padding)
    var table_min: int = pad
    var table_max: int = max(table_min, grid_extent - 1 - pad)
    var rim_height: int = max(0, table_rim_height)
    var bowl_radius: float = maxf(2.0, float(grid_extent) * bowl_radius_ratio)
    var bowl_wall: int = max(1, bowl_wall_thickness)
    var bowl_inner: float = maxf(1.0, bowl_radius - float(bowl_wall))
    var bowl_min_x: float = maxf(float(table_min) + bowl_radius + 1.0, bowl_radius + 1.0)
    var bowl_max_x: float = minf(float(table_max) - bowl_radius - 1.0, float(grid_extent) - bowl_radius - 2.0)
    var bowl_min_z: float = bowl_min_x
    var bowl_max_z: float = bowl_max_x
    var bowl_center_x: float = center
    var bowl_center_y: float = float(floor_y_max) + bowl_radius
    var bowl_center_z: float = center
    var bowl_center := Vector3(bowl_center_x, bowl_center_y, bowl_center_z)
    var bowl_inner_bottom: float = bowl_center_y - bowl_inner
    var bowl_sand_top: float = bowl_inner_bottom + bowl_inner * bowl_sand_height_ratio
    var bowl_sand_radius: float = maxf(1.0, bowl_inner - sand_clearance)

    var cup_radius: float = maxf(2.0, float(grid_extent) * cup_radius_ratio)
    var cup_wall: int = max(1, cup_wall_thickness)
    var cup_inner: float = maxf(1.0, cup_radius - float(cup_wall))
    var cup_height_target: float = float(grid_extent) * cup_height_ratio
    var cup_height_max: float = maxf(3.0, float(grid_extent - floor_y_max - 2))
    var cup_height: float = clampf(maxf(3.0, cup_height_target), 3.0, cup_height_max)
    var cup_bottom: float = float(floor_y_max)
    var cup_top: float = cup_bottom + cup_height
    var cup_inner_height: float = maxf(1.0, cup_height - float(cup_wall))
    var cup_sand_top: float = cup_bottom + cup_inner_height * cup_sand_height_ratio
    var cup_sand_radius: float = maxf(1.0, cup_inner - sand_clearance)
    var cup_min_x: float = maxf(float(table_min) + cup_radius + 1.0, cup_radius + 1.0)
    var cup_max_x: float = minf(float(table_max) - cup_radius - 1.0, float(grid_extent) - cup_radius - 2.0)
    var cup_min_z: float = cup_min_x
    var cup_max_z: float = cup_max_x
    var cup_center_x: float = center
    var cup_center_z: float = center

    var usable_min: float = float(table_min + 2)
    var usable_max: float = float(table_max - 2)
    var usable_half: float = minf(center - usable_min, usable_max - center)
    var desired_gap: float = maxf(bowl_cup_gap_min, float(grid_extent) * bowl_cup_gap_ratio)
    var max_gap: float = maxf(0.0, 2.0 * (usable_half - bowl_radius - cup_radius))
    var gap: float = minf(desired_gap, max_gap)
    var center_sep: float = bowl_radius + cup_radius + gap
    var desired_offset: float = center_sep / (2.0 * sqrt(2.0))
    var offset_limit_bowl: float = minf(center - bowl_min_x, center - bowl_min_z)
    var offset_limit_cup: float = minf(cup_max_x - center, cup_max_z - center)
    var offset: float = minf(desired_offset, minf(offset_limit_bowl, offset_limit_cup))
    if offset < 0.0:
        offset = 0.0
    if usable_half > 0.0:
        bowl_center_x = center - offset
        bowl_center_z = center - offset
        cup_center_x = center + offset
        cup_center_z = center + offset
        bowl_center_x = clampf(bowl_center_x, bowl_min_x, bowl_max_x)
        bowl_center_z = clampf(bowl_center_z, bowl_min_z, bowl_max_z)
        cup_center_x = clampf(cup_center_x, cup_min_x, cup_max_x)
        cup_center_z = clampf(cup_center_z, cup_min_z, cup_max_z)
    bowl_center = Vector3(bowl_center_x, bowl_center_y, bowl_center_z)
    var cup_center := Vector3(cup_center_x, cup_bottom + cup_height * 0.5, cup_center_z)
    var entries: Array = []

    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var y_f: float = float(y)
                var pos := Vector3(float(x), y_f, float(z))
                var in_table: bool = (
                    x >= table_min and x <= table_max
                    and z >= table_min and z <= table_max
                )
                if !in_table:
                    continue
                var is_floor: bool = y < floor_y_max
                var is_rim: bool = (
                    rim_height > 0
                    and y >= floor_y_max and y < (floor_y_max + rim_height)
                    and (x == table_min or x == table_max or z == table_min or z == table_max)
                )

                var bowl_dx: float = pos.x - bowl_center.x
                var bowl_dy: float = pos.y - bowl_center.y
                var bowl_dz: float = pos.z - bowl_center.z
                var bowl_dist: float = sqrt(bowl_dx * bowl_dx + bowl_dy * bowl_dy + bowl_dz * bowl_dz)
                var bowl_shell: bool = bowl_dy <= 0.0 and bowl_dist <= bowl_radius and bowl_dist >= bowl_inner
                var in_bowl: bool = (
                    bowl_dy <= 0.0
                    and pos.y >= bowl_inner_bottom
                    and pos.y <= bowl_sand_top
                    and bowl_dist <= bowl_sand_radius
                )

                var cup_dx: float = pos.x - cup_center.x
                var cup_dz: float = pos.z - cup_center.z
                var cup_r: float = sqrt(cup_dx * cup_dx + cup_dz * cup_dz)
                var cup_in_height: bool = pos.y >= cup_bottom and pos.y <= cup_top
                var cup_side_shell: bool = cup_in_height and cup_r <= cup_radius and cup_r >= cup_inner
                var cup_bottom_shell: bool = pos.y >= cup_bottom and pos.y <= (cup_bottom + float(cup_wall)) and cup_r <= cup_radius
                var cup_shell: bool = cup_side_shell or cup_bottom_shell
                var in_cup: bool = (
                    pos.y >= (cup_bottom + float(cup_wall))
                    and pos.y <= cup_sand_top
                    and cup_r <= cup_sand_radius
                )

                if is_floor or is_rim or bowl_shell or cup_shell:
                    entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
                    continue
                if (in_bowl or in_cup) and _rng.randf() <= sand_density:
                    entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})

    _renderer.set_voxel_entries(entries, true)
