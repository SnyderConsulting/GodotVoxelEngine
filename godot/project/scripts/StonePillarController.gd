extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"

@export var stone_material_id: int = 4
@export var invisible_material_id: int = 9

@export var pillar_length_cells: int = 10
@export var pillar_thickness_cells: int = 2
@export var anchor_length_cells: int = 2
@export var anchor_static: bool = true

@export var drop_weight_delay: float = 1.0
@export var weight_size_cells: int = 3
@export var weight_material_id: int = 4
@export var random_seed: int = 1337

const FLAG_STATIC := 1 << 1

var _time: float = 0.0
var _dropped_once: bool = false
var _tip_cell := Vector3i(-1, -1, -1)
var _base_y: int = 0

func _ready() -> void:
    bind(voxel_renderer_path, overlay_path, random_seed)
    if renderer == null:
        push_error("StonePillarController missing VoxelRenderer.")
        return
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(Callable(self, "_start_scene"))

func _start_scene() -> void:
    renderer.sim_mode = 1
    _build_scene()
    renderer.gravity_dir = Vector3(0, -1, 0)
    _update_overlay()

func _process(delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return

    _time += delta
    if !_dropped_once and drop_weight_delay >= 0.0 and _time >= drop_weight_delay:
        _dropped_once = true
        _drop_weight()

    # Space/Enter drops another weight.
    if Input.is_action_just_pressed("ui_accept"):
        _drop_weight()

func _update_overlay() -> void:
    if overlay == null or renderer == null:
        return
    update_overlay_text(compose_overlay(
        "Stone Pillar Test",
        "Acceptance Test B: cantilever pillar + dropped weight. Enter: drop weight.",
        renderer,
        true,
        true,
        true
    ))

func _build_scene() -> void:
    if renderer == null:
        return
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var center: int = int((grid_extent - 1) / 2)

    var entries: Array = []

    # Invisible floor slab.
    var floor_thickness: int = 3
    for y in range(floor_thickness):
        for z in range(grid_extent):
            for x in range(grid_extent):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                entries.append({"pos": Vector3(x, y, z), "material": invisible_material_id})

    # A backstop wall to make the support end unambiguously "fixed".
    var wall_x: int = center - (pillar_length_cells * 2) / 2 - 2
    for z in range(grid_extent):
        for y in range(floor_thickness, grid_extent - 2):
            if !((wall_x & 1) == (y & 1) and (y & 1) == (z & 1)):
                continue
            entries.append({"pos": Vector3(wall_x, y, z), "material": invisible_material_id})

    # Build a 10x2x2 pillar of stone (counts are in BCC cells, so coordinate stride is 2).
    var base_x: int = center - (pillar_length_cells * 2) / 2
    _base_y = int(grid_extent * 0.55)
    var base_z: int = center - (pillar_thickness_cells * 2) / 2

    # Ensure the pillar lives on valid BCC lattice points (even-even-even or odd-odd-odd).
    # We step by 2 in each dimension, so fixing the base parity is sufficient.
    var parity: int = base_x & 1
    if (_base_y & 1) != parity:
        _base_y -= 1
    if (base_z & 1) != parity:
        base_z -= 1
    _base_y = clampi(_base_y, 0, grid_extent - 1)
    base_z = clampi(base_z, 0, grid_extent - 1)

    for i in range(pillar_length_cells):
        for ty in range(pillar_thickness_cells):
            for tz in range(pillar_thickness_cells):
                var cell := Vector3i(
                    base_x + i * 2,
                    _base_y + ty * 2,
                    base_z + tz * 2
                )
                var flags := 0
                if anchor_static and i < anchor_length_cells:
                    flags |= FLAG_STATIC
                entries.append({
                    "pos": Vector3(cell.x, cell.y, cell.z),
                    "material": stone_material_id,
                    "flags": flags
                })

    _tip_cell = Vector3i(base_x + (pillar_length_cells - 1) * 2, _base_y, base_z)

    if renderer.has_method("set_voxel_entries_mpm"):
        renderer.set_voxel_entries_mpm(entries)
    else:
        renderer.set_voxel_entries(entries, true)

func _drop_weight() -> void:
    if renderer == null or !renderer.has_method("mpm_spawn_cells"):
        return
    if _tip_cell.x < 0:
        return
    var cells: Array = []
    var half: int = maxi(0, weight_size_cells / 2)
    var spawn_y: int = _base_y + 18
    for dz in range(-half, half + 1):
        for dy in range(-half, half + 1):
            for dx in range(-half, half + 1):
                # Keep weight centered near the pillar tip.
                var c := Vector3i(_tip_cell.x + dx * 2, spawn_y + dy * 2, _tip_cell.z + dz * 2)
                cells.append(c)
    renderer.mpm_spawn_cells(cells, weight_material_id, Vector3.ZERO, 1.0, 0)
