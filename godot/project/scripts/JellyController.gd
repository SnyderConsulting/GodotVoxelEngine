extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"

@export var stone_material_id: int = 4
@export var invisible_material_id: int = 9
@export var block_size_cells: int = 6
@export var random_seed: int = 2026

func _ready() -> void:
    bind(voxel_renderer_path, overlay_path, random_seed)
    if renderer == null:
        push_error("JellyController missing VoxelRenderer.")
        return
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(Callable(self, "_start_scene"))

func _start_scene() -> void:
    # This scene is used as the automated stability regression.
    # Run with gravity disabled and fracture disabled to isolate "MPM jelly" drift.
    renderer.sim_enabled = false
    renderer.sim_mode = 1
    renderer.mpm_gravity_strength = 0.0
    renderer.mpm_fracture_enabled = false
    _build_scene()
    renderer.gravity_dir = Vector3(0, -1, 0)
    renderer.sim_enabled = true
    _update_overlay()

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)

func _update_overlay() -> void:
    if overlay == null or renderer == null:
        return
    update_overlay_text(compose_overlay(
        "Jelly Test",
        "Acceptance Test C: stone block should not drift/melt over time. (gravity=0, fracture=off)",
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

    # Stone block above the floor.
    var base_x: int = center - (block_size_cells * 2) / 2
    var base_y: int = floor_thickness + 6
    var base_z: int = center - (block_size_cells * 2) / 2

    for zc in range(block_size_cells):
        for yc in range(block_size_cells):
            for xc in range(block_size_cells):
                var cell := Vector3i(
                    base_x + xc * 2,
                    base_y + yc * 2,
                    base_z + zc * 2
                )
                entries.append({"pos": Vector3(cell.x, cell.y, cell.z), "material": stone_material_id})

    if renderer.has_method("set_voxel_entries_mpm"):
        renderer.set_voxel_entries_mpm(entries)
    else:
        renderer.set_voxel_entries(entries, true)
