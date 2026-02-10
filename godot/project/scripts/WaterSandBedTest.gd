extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var water_material_id: int = 2
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var random_seed: int = 4242

# Build a flat sand bed that is marked static/bedrock, then drop water on top.
# This test is intended to validate the current "impermeable" assumption: water should not sink into sand.
@export var bed_base_y: int = 2
@export var bed_height: int = 10
@export var bed_static_flags: int = 2 # FLAG_STATIC (1<<1) in shaders

@export var water_layers: int = 4
@export var water_top_margin: int = 2

func _ready() -> void:
	bind(voxel_renderer_path, overlay_path, random_seed)
	if renderer == null:
		push_error("WaterSandBedTest missing VoxelRenderer.")
		return
	call_deferred("_initialize_scenario")

func _initialize_scenario() -> void:
	wait_for_renderer_ready(Callable(self, "_build_scene"))

func _build_scene() -> void:
	if renderer == null:
		return
	# Prevent a few frames of sim from running on an empty/uninitialized scenario.
	renderer.sim_enabled = false
	renderer.sim_mode = 1

	var entries: Array = []
	_build_container(entries)
	_build_sand_bed(entries)
	_spawn_water(entries)

	if renderer.has_method("set_voxel_entries_mpm"):
		renderer.set_voxel_entries_mpm(entries)
	else:
		renderer.set_voxel_entries(entries, true)

	renderer.gravity_dir = Vector3(0, -1, 0)
	renderer.sim_enabled = true
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
		"Water On Sand Bed Test",
		"Water should remain above a static sand bed (impermeable assumption).",
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
				if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
					continue
				var is_wall := (x == min_wall or x == max_wall or z == min_wall or z == max_wall or y == min_wall)
				if is_wall:
					entries.append({"pos": Vector3(x, y, z), "material": glass_material_id})

func _build_sand_bed(entries: Array) -> void:
	var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
	var min_wall := 1
	var max_wall := grid_extent - 2
	var interior_min := min_wall + 1
	var interior_max := max_wall - 1

	var y0 := clampi(bed_base_y, interior_min, interior_max)
	var y1 := clampi(bed_base_y + maxi(1, bed_height) - 1, interior_min, interior_max)
	for z in range(interior_min, interior_max + 1):
		for y in range(y0, y1 + 1):
			for x in range(interior_min, interior_max + 1):
				if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
					continue
				entries.append({"pos": Vector3(x, y, z), "material": sand_material_id, "flags": bed_static_flags})

func _spawn_water(entries: Array) -> void:
	var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
	var min_wall := 1
	var max_wall := grid_extent - 2
	var interior_min := min_wall + 1
	var interior_max := max_wall - 1
	var top := grid_extent - 2 - maxi(0, water_top_margin)
	var layers := maxi(1, water_layers)
	var y0 := clampi(top - layers + 1, interior_min, interior_max)
	var y1 := clampi(top, interior_min, interior_max)
	for z in range(interior_min, interior_max + 1):
		for y in range(y0, y1 + 1):
			for x in range(interior_min, interior_max + 1):
				if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
					continue
				entries.append({"pos": Vector3(x, y, z), "material": water_material_id})

