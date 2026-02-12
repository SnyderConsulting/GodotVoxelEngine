extends "res://scripts/BaseVoxelShared.gd"
@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var fill_height_ratio: float = 0.55
@export var sand_density: float = 0.75
@export var wall_thickness: int = 1
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var random_seed: int = 1337

func _ready() -> void:
    bind(voxel_renderer_path, overlay_path, random_seed)
    if renderer == null:
        push_error("TumblerController missing VoxelRenderer.")
        return
    call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
    wait_for_renderer_ready(Callable(self, "_start_scene"))

func _start_scene() -> void:
    begin_scene_build(1)
    _build_tumbler()
    end_scene_build(true)
    _update_overlay()

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return
    _update_overlay()

func _update_overlay() -> void:
    if overlay == null or renderer == null:
        return
    update_overlay_text(compose_overlay("Tumbler Test", "", renderer, true, false, true))

func _build_tumbler() -> void:
    if renderer == null:
        return
    var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
    var min_wall := wall_thickness
    var max_wall := grid_extent - 1 - wall_thickness
    var fill_height := int(round(float(grid_extent) * fill_height_ratio))
    var entries: Array = []
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !is_bcc_cell(x, y, z):
                    continue
                var is_wall := (
                    x < min_wall or x > max_wall
                    or y < min_wall or y > max_wall
                    or z < min_wall or z > max_wall
                )
                if is_wall:
                    entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})
                    continue
                if y <= fill_height and rng.randf() <= sand_density:
                    entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})
    apply_entries(entries, true)
