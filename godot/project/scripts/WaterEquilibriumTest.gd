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
    if renderer != null:
        # Prevent a few frames of sim from running on an empty/uninitialized scenario.
        renderer.sim_enabled = false
        renderer.sim_mode = 1
    _spawned_cells.clear()
    _build_container()
    _spawn_water()
    renderer.gravity_dir = Vector3(0, -1, 0)
    if renderer != null:
        renderer.sim_enabled = true
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
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var is_wall := (x == min_wall or x == max_wall or z == min_wall or z == max_wall or y == min_wall)
                if is_wall:
                    entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
    if renderer.has_method("set_voxel_entries_mpm"):
        renderer.set_voxel_entries_mpm(entries)
    else:
        renderer.set_voxel_entries(entries, true)

func _spawn_water() -> void:
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center := int((grid_extent - 1) * 0.5)
    var radius := 8
    var top := grid_extent - 2
    var min_wall := 1
    var max_wall := grid_extent - 2
    for z in range(center - radius, center + radius + 1):
        for x in range(center - radius, center + radius + 1):
            var cell := _snap_to_bcc(Vector3i(x, top, z), grid_extent)
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

func _snap_to_bcc(cell: Vector3i, grid_extent: int) -> Vector3i:
    if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    if ((cell.x & 1) == (cell.y & 1)) and ((cell.y & 1) == (cell.z & 1)):
        return cell
    var y1 := cell.y - 1
    if y1 >= 0 and ((cell.x & 1) == (y1 & 1)) and ((y1 & 1) == (cell.z & 1)):
        return Vector3i(cell.x, y1, cell.z)
    var y2 := cell.y + 1
    if y2 < grid_extent and ((cell.x & 1) == (y2 & 1)) and ((y2 & 1) == (cell.z & 1)):
        return Vector3i(cell.x, y2, cell.z)
    var x2 := cell.x + 1
    if x2 < grid_extent and ((x2 & 1) == (cell.y & 1)) and ((cell.y & 1) == (cell.z & 1)):
        return Vector3i(x2, cell.y, cell.z)
    var x1 := cell.x - 1
    if x1 >= 0 and ((x1 & 1) == (cell.y & 1)) and ((cell.y & 1) == (cell.z & 1)):
        return Vector3i(x1, cell.y, cell.z)
    return Vector3i(-1, -1, -1)
