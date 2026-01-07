extends Node

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var bulb_radius_ratio: float = 0.45
@export var neck_radius_ratio: float = 0.12
@export var wall_thickness: int = 2
@export var shell_padding: float = 0.45
@export var sand_clearance: float = 0.35
@export var sand_density: float = 0.85
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var random_seed: int = 4242

var _renderer: Node = null
var _overlay: Label = null
var _rng := RandomNumberGenerator.new()
var _init_attempts: int = 0

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _overlay = get_node_or_null(overlay_path) as Label
    if _renderer == null:
        push_error("HourglassController missing VoxelRenderer.")
        return
    _rng.seed = random_seed
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    if !_wait_for_renderer_ready():
        return
    _build_hourglass()
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
            push_error("HourglassController renderer not ready.")
        return false
    return true

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)

func _update_overlay() -> void:
    if _overlay == null:
        return
    _overlay.text = (
        "Hourglass Test\n"
        + "Use sliders for gravity/world rotation | Esc: hub\n"
        + "Glass: outline only, sand falls through neck."
    )

func _build_hourglass() -> void:
    var grid_extent: int = _renderer.chunk_grid * _renderer.chunk_size
    var center: float = (float(grid_extent) - 1.0) * 0.5
    var half: float = maxf(center, 1.0)
    var bulb_radius: float = float(grid_extent) * bulb_radius_ratio
    var neck_radius: float = maxf(1.0, float(grid_extent) * neck_radius_ratio)
    var inner_wall: float = float(wall_thickness)
    var entries: Array = []

    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
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
                    continue
                var sand_limit := maxf(radius - inner_wall - sand_clearance, 0.0)
                if y > int(center + 1.0) and r < sand_limit:
                    if _rng.randf() <= sand_density:
                        entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})

    _renderer.set_voxel_entries(entries, true)
