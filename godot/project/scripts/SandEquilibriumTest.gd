extends "res://scripts/BaseVoxelShared.gd"

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var random_seed: int = 4242

# Spawn a dense sand block near the top so it collapses into a pile and then (ideally) comes to rest.
@export var sand_block_size_x: int = 18
@export var sand_block_size_z: int = 18
@export var sand_block_layers_y: int = 8
@export var sand_block_top_margin: int = 3

func _ready() -> void:
	bind(voxel_renderer_path, overlay_path, random_seed)
	if renderer == null:
		push_error("SandEquilibriumTest missing VoxelRenderer.")
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
	_spawn_sand_block(entries)

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
		"Sand Equilibrium Test",
		"Sand block should collapse and settle (low residual motion).",
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

func _spawn_sand_block(entries: Array) -> void:
	var grid_extent: int = renderer.chunk_grid * renderer.chunk_size
	var min_wall := 1
	var max_wall := grid_extent - 2
	var interior_min := min_wall + 1
	var interior_max := max_wall - 1

	var cx := int((grid_extent - 1) * 0.5)
	var cz := int((grid_extent - 1) * 0.5)
	var half_x := int(max(2, sand_block_size_x / 2))
	var half_z := int(max(2, sand_block_size_z / 2))

	var x0 := clampi(cx - half_x, interior_min, interior_max)
	var x1 := clampi(cx + half_x, interior_min, interior_max)
	var z0 := clampi(cz - half_z, interior_min, interior_max)
	var z1 := clampi(cz + half_z, interior_min, interior_max)

	var top := grid_extent - 2 - maxi(0, sand_block_top_margin)
	var y0 := clampi(top - maxi(0, sand_block_layers_y) + 1, interior_min, interior_max)
	var y1 := clampi(top, interior_min, interior_max)

	for z in range(z0, z1 + 1):
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
					continue
				entries.append({"pos": Vector3(x, y, z), "material": sand_material_id})

