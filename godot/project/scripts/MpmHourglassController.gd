extends "res://scripts/BaseVoxelShared.gd"

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
@export var debug_escape_metrics: bool = true
@export var debug_escape_every: int = 60

var _hourglass_center: float = 0.0
var _hourglass_half: float = 1.0
var _hourglass_bulb_radius: float = 1.0
var _hourglass_neck_radius: float = 1.0
var _process_frame: int = 0

func _ready() -> void:
    bind(voxel_renderer_path, overlay_path, random_seed)
    if renderer == null:
        push_error("MpmHourglassController missing VoxelRenderer.")
        return
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(Callable(self, "_start_scene"))

func _start_scene() -> void:
    if renderer != null:
        renderer.sim_mode = 1
    _build_hourglass()
    renderer.gravity_dir = Vector3(0, -1, 0)
    _update_overlay()

func _process(_delta: float) -> void:
    _process_frame += 1
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
    if !debug_escape_metrics:
        return
    if renderer == null:
        return
    if !renderer.debug_logging:
        return
    renderer.debug_mpm_hourglass_metrics(
        sand_material_id,
        _hourglass_center,
        _hourglass_half,
        _hourglass_bulb_radius,
        _hourglass_neck_radius,
        wall_thickness,
        shell_padding,
        float(wall_thickness),
        debug_escape_every
    )

func _update_overlay() -> void:
    if overlay == null or renderer == null:
        return
    update_overlay_text(compose_overlay(
        "MPM Hourglass Test",
        "MPM prototype: particles rasterize into the voxel atlas for rendering.",
        renderer,
        true,
        true,
        true))

func _build_hourglass() -> void:
    if renderer == null:
        return
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center: float = (float(grid_extent) - 1.0) * 0.5
    var half: float = maxf(center, 1.0)
    var bulb_radius: float = float(grid_extent) * bulb_radius_ratio
    var neck_radius: float = maxf(1.0, float(grid_extent) * neck_radius_ratio)
    var inner_wall: float = float(wall_thickness)
    var entries: Array = []

    _hourglass_center = center
    _hourglass_half = half
    _hourglass_bulb_radius = bulb_radius
    _hourglass_neck_radius = neck_radius

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
                var sand_limit := maxf(radius - inner_wall - sand_clearance, 0.00)
                if y > int(center + 1.0) and r < sand_limit:
                    if rng.randf() <= sand_density:
                        entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})

    if renderer.has_method("set_voxel_entries_mpm"):
        renderer.set_voxel_entries_mpm(entries)
    else:
        renderer.set_voxel_entries(entries, true)
