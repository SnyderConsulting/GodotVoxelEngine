extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var water_material_id: int = 2
@export var glass_material_id: int = 8
@export var random_seed: int = 4242

# Spawn a large, offset blob of water to force lateral flow before settling.
# Intended to mimic "paint mode" style usage on a larger grid.
@export var water_blob_size_x: int = 42
@export var water_blob_size_z: int = 42
@export var water_blob_layers_y: int = 10
@export var water_blob_offset_x: int = 4
@export var water_blob_offset_z: int = 4
@export var water_blob_top_margin: int = 4

func _ready() -> void:
	bind(voxel_renderer_path, overlay_path, random_seed)
	if renderer == null:
		push_error("WaterLevelingLargeTest missing VoxelRenderer.")
		return
	call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
	wait_for_renderer_ready(Callable(self, "_build_scene"))

func _build_scene() -> void:
	if renderer == null:
		return
	begin_scene_build(1)

	var entries: Array = []
	_build_container(entries)
	_spawn_water_blob(entries)

	apply_entries(entries, true)

	renderer.gravity_dir = Vector3(0, -1, 0)
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
	update_overlay_text(compose_overlay(
		"Water Leveling (Large) Test",
		"Water blob should spread/level (not pile like sand).",
		renderer,
		true,
		true,
		false))

func _build_container(entries: Array) -> void:
	var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
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

func _spawn_water_blob(entries: Array) -> void:
	var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
	var min_wall := 1
	var max_wall := grid_extent - 2
	var interior_min := min_wall + 1
	var interior_max := max_wall - 1

	# Offset blob towards one corner to ensure it must flow laterally before it can settle.
	var x0 := clampi(min_wall + maxi(1, water_blob_offset_x), interior_min, interior_max)
	var z0 := clampi(min_wall + maxi(1, water_blob_offset_z), interior_min, interior_max)
	var x1 := clampi(x0 + maxi(2, water_blob_size_x) - 1, interior_min, interior_max)
	var z1 := clampi(z0 + maxi(2, water_blob_size_z) - 1, interior_min, interior_max)

	var top := grid_extent - 2 - maxi(0, water_blob_top_margin)
	var y0 := clampi(top - maxi(1, water_blob_layers_y) + 1, interior_min, interior_max)
	var y1 := clampi(top, interior_min, interior_max)

	for z in range(z0, z1 + 1):
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if !is_bcc_cell(x, y, z):
					continue
				entries.append({"pos": Vector3(x, y, z), "material": water_material_id})
