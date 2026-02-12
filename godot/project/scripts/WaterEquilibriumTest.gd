extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var water_material_id: int = 2
@export var glass_material_id: int = 8
@export var random_seed: int = 4242
@export var drop_count: int = 200
@export var log_every: float = 1.0

var _accum := 0.0
var _spawned_cells := {}

func _ready() -> void:
    bind(voxel_renderer_path, overlay_path, random_seed)
    if renderer == null:
        push_error("WaterEquilibriumTest missing VoxelRenderer.")
        return
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(Callable(self, "_start_scene"))

func _start_scene() -> void:
    begin_scene_build(1)
    _spawned_cells.clear()
    _build_container()
    _spawn_water()
    renderer.gravity_dir = Vector3(0, -1, 0)
    end_scene_build(true)
    _update_overlay()

func _process(delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return
    _accum += delta
    if _accum >= log_every:
        _accum = 0.0
        if renderer != null and renderer.has_method("debug_material_column_metrics"):
            renderer.debug_material_column_metrics(water_material_id)
    _update_overlay()

func _update_overlay() -> void:
    if overlay == null or renderer == null:
        return
    update_overlay_text(compose_overlay(
        "Water Equilibrium Test",
        "Auto-logs column height variance.",
        renderer,
        true,
        true,
        false))

func _build_container() -> void:
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var entries: Array = []
    var min_wall := 1
    var max_wall := grid_extent - 2
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !is_bcc_cell(x, y, z):
                    continue
                var is_wall := (x == min_wall or x == max_wall or z == min_wall or z == max_wall or y == min_wall)
                if is_wall:
                    entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
    apply_entries(entries, true)

func _spawn_water() -> void:
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center := int((grid_extent - 1) * 0.5)
    var radius := 8
    var top := grid_extent - 2
    var min_wall := 1
    var max_wall := grid_extent - 2
    for z in range(center - radius, center + radius + 1):
        for x in range(center - radius, center + radius + 1):
            var cell := snap_to_bcc(Vector3i(x, top, z), grid_extent)
            if cell.x < 0:
                continue
            if cell.x == min_wall or cell.x == max_wall or cell.z == min_wall or cell.z == max_wall or cell.y == min_wall:
                continue
            var key := cell.x + cell.y * grid_extent + cell.z * grid_extent * grid_extent
            if _spawned_cells.has(key):
                continue
            _spawned_cells[key] = true
            if renderer.has_method("set_voxel_at"):
                renderer.set_voxel_at(cell, water_material_id)
