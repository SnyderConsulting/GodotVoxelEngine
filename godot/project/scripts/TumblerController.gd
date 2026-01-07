extends Node

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var rotation_speed: float = 0.9
@export var roll_speed: float = 0.9
@export var fill_height_ratio: float = 0.55
@export var sand_density: float = 0.75
@export var wall_thickness: int = 1
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var random_seed: int = 1337

var _renderer: Node = null
var _overlay: Label = null
var _angles := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _init_attempts: int = 0

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _overlay = get_node_or_null(overlay_path) as Label
    if _renderer == null:
        push_error("TumblerController missing VoxelRenderer.")
        return
    _rng.seed = random_seed
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    if !_wait_for_renderer_ready():
        return
    _build_tumbler()
    _apply_gravity()
    _update_overlay()

func _wait_for_renderer_ready() -> bool:
    if _renderer == null:
        return false
    if _renderer.has_method("is_render_ready") and !_renderer.is_render_ready():
        _init_attempts += 1
        if _init_attempts <= 120:
            call_deferred("_initialize_scenario")
        else:
            push_error("TumblerController renderer not ready.")
        return false
    return true

func _process(delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return

    var delta_angles := Vector3.ZERO
    if Input.is_action_pressed("ui_left"):
        delta_angles.y += rotation_speed * delta
    if Input.is_action_pressed("ui_right"):
        delta_angles.y -= rotation_speed * delta
    if Input.is_action_pressed("ui_up"):
        delta_angles.x += rotation_speed * delta
    if Input.is_action_pressed("ui_down"):
        delta_angles.x -= rotation_speed * delta
    if Input.is_action_pressed("ui_page_up"):
        delta_angles.z += roll_speed * delta
    if Input.is_action_pressed("ui_page_down"):
        delta_angles.z -= roll_speed * delta
    var reset := Input.is_key_pressed(KEY_R)
    if reset:
        _angles = Vector3.ZERO
        delta_angles = Vector3.ZERO
    if delta_angles != Vector3.ZERO or reset:
        _angles += delta_angles
        _apply_gravity()
        _update_overlay()

func _apply_gravity() -> void:
    var basis := Basis.from_euler(_angles)
    var gravity := basis * Vector3.DOWN
    _renderer.gravity_dir = gravity.normalized()

func _update_overlay() -> void:
    if _overlay == null:
        return
    var degrees := _angles * 180.0 / PI
    var gravity = _renderer.gravity_dir
    _overlay.text = (
        "Tumbler Test\n"
        + "Arrows: pitch/yaw | PgUp/PgDn: roll | R: reset | Esc: hub\n"
        + "Pitch/Yaw/Roll deg: (%.1f, %.1f, %.1f)\n"
        + "Gravity: (%.2f, %.2f, %.2f)"
    ) % [degrees.x, degrees.y, degrees.z, gravity.x, gravity.y, gravity.z]

func _build_tumbler() -> void:
    var grid_extent: int = _renderer.chunk_grid * _renderer.chunk_size
    var min_wall := wall_thickness
    var max_wall := grid_extent - 1 - wall_thickness
    var fill_height := int(round(float(grid_extent) * fill_height_ratio))
    var entries: Array = []
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var is_wall := (
                    x < min_wall or x > max_wall
                    or y < min_wall or y > max_wall
                    or z < min_wall or z > max_wall
                )
                if is_wall:
                    entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
                    continue
                if y <= fill_height and _rng.randf() <= sand_density:
                    entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})
    _renderer.set_voxel_entries(entries, true)
