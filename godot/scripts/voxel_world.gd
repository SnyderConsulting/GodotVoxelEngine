extends Node3D
class_name VoxelWorld

const MAT_EMPTY := 0
const MAT_SAND := 1
const MAT_WALL := 2
const MAT_MASK := 3
const ACTIVE_MASK := 4
const VACUUM_MASK := 8
const VACUUM_MOVED := 16

@export var voxel_size := 1.0
@export var static_color := Color(0.90, 0.82, 0.62)
@export var grid_size := Vector3i(32, 16, 32)
@export var grid_origin := Vector3i(-16, 0, -16)
@export var brick_size := 8
@export var sim_step := 0.033333
@export var use_gpu := true
@export var cpu_render := false
@export var gpu_only := true
@export var debug_readback := true

var _static_mesh := BoxMesh.new()
var _static_multimesh := MultiMesh.new()
var _static_instance := MultiMeshInstance3D.new()

var _grid: PackedInt32Array = PackedInt32Array()
var _grid_dirty := false
var _grid_version := 0
var _sim_accum := 0.0
var _sim_step_id := 0
var _last_sim_time_us := 0
var _last_sim_steps := 0
var _last_sim_mode := "cpu"

var _vacuum_target := Vector3.ZERO
var _vacuum_target_grid := Vector3.ZERO
var _vacuum_target_grid_local := Vector3.ZERO
var _vacuum_capture_radius := 1.0
var _vacuum_tagged_step := 0
var _vacuum_collected_step := 0
var _vacuum_collected_total := 0

var _gpu: Node = null

func _ready() -> void:
	if brick_size != 8:
		brick_size = 8
	_static_mesh.size = Vector3(voxel_size, voxel_size, voxel_size)
	_static_multimesh.mesh = _static_mesh
	_static_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_static_instance.multimesh = _static_multimesh
	_static_instance.material_override = _make_material(static_color)
	_static_instance.visible = cpu_render
	add_child(_static_instance)

	_init_grid()

func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	return material

func _init_grid() -> void:
	var count := grid_size.x * grid_size.y * grid_size.z
	_grid = PackedInt32Array()
	_grid.resize(count)
	for i in count:
		_grid[i] = 0
	_grid_dirty = true
	if use_gpu:
		_gpu = _create_gpu()

func _create_gpu() -> Node:
	var gpu: Node = load("res://scripts/gpu_compute.gd").new()
	var ok := bool(gpu.call("setup", grid_size, brick_size))
	if not ok:
		push_error("[gpu] setup failed")
		return null
	gpu.call("set_readback_enabled", debug_readback)
	gpu.call("upload_grid", _grid)
	print("[gpu] setup ok")
	return gpu

func step_sim(delta: float) -> void:
	_sim_accum += delta
	var start_us: int = Time.get_ticks_usec()
	var steps: int = 0
	while _sim_accum >= sim_step:
		_sim_accum -= sim_step
		_sim_step_id += 1
		_vacuum_collected_step = 0
		if use_gpu and _gpu != null:
			_gpu.call("step_inplace", _sim_step_id, _vacuum_target_grid_local, _vacuum_capture_radius)
			if not gpu_only:
				_grid = _gpu.call("download_grid")
				_grid_dirty = true
				_grid_version += 1
			_last_sim_mode = "gpu"
			var counts: Dictionary = _gpu.call("get_last_counts")
			_vacuum_collected_step = int(counts.get("deleted", 0))
			_vacuum_collected_total += _vacuum_collected_step
		else:
			if use_gpu and _gpu == null:
				use_gpu = false
			_step_sand_cpu()
			_last_sim_mode = "cpu"
		steps += 1
	if _grid_dirty:
		if cpu_render:
			_rebuild_static_multimesh()
		_grid_dirty = false
	if steps > 0:
		_last_sim_time_us = Time.get_ticks_usec() - start_us
		_last_sim_steps = steps

func spawn_cube(origin: Vector3i, size: Vector3i) -> void:
	for x in size.x:
		for y in size.y:
			for z in size.z:
				add_voxel(origin + Vector3i(x, y, z))
	if cpu_render:
		_rebuild_static_multimesh()

func add_voxel(grid_pos: Vector3i) -> void:
	if not _is_in_bounds(grid_pos):
		return
	var index := _grid_index(grid_pos)
	if (_grid[index] & MAT_MASK) == MAT_SAND:
		return
	_grid[index] = MAT_SAND
	_grid_dirty = true
	_grid_version += 1
	if use_gpu and _gpu != null:
		_gpu.call("upload_grid", _grid)

func remove_voxel(grid_pos: Vector3i) -> bool:
	if not _is_in_bounds(grid_pos):
		return false
	var index := _grid_index(grid_pos)
	if (_grid[index] & MAT_MASK) == MAT_EMPTY:
		return false
	_grid[index] = MAT_EMPTY
	_grid_dirty = true
	_grid_version += 1
	if use_gpu and _gpu != null:
		_gpu.call("upload_grid", _grid)
	return true

func set_vacuum_target(target: Vector3, capture_radius: float) -> void:
	_vacuum_target = target
	_vacuum_target_grid = target / voxel_size
	_vacuum_target_grid_local = _vacuum_target_grid - Vector3(grid_origin)
	_vacuum_capture_radius = max(capture_radius / voxel_size, 0.1)

func vacuum_from_ray(ray_origin: Vector3, ray_dir: Vector3, max_dist: float, radius: float, max_count: int) -> int:
	if use_gpu and gpu_only:
		return 0
	var hit: Variant = pick_voxel(ray_origin, ray_dir, max_dist)
	if hit == null:
		_vacuum_tagged_step = 0
		return 0
	return vacuum_in_sphere(grid_to_world(hit), radius, max_count)

func vacuum_in_sphere(center: Vector3, radius: float, max_count: int) -> int:
	var radius_grid := radius / voxel_size
	var radius_sq := radius_grid * radius_grid
	var center_grid := world_to_grid(center)
	var min_grid := center_grid - Vector3i(ceil(radius_grid), ceil(radius_grid), ceil(radius_grid))
	var max_grid := center_grid + Vector3i(ceil(radius_grid), ceil(radius_grid), ceil(radius_grid))

	var tagged := 0
	for x in range(min_grid.x, max_grid.x + 1):
		for y in range(min_grid.y, max_grid.y + 1):
			for z in range(min_grid.z, max_grid.z + 1):
				if tagged >= max_count:
					break
				var grid_pos := Vector3i(x, y, z)
				if not _is_in_bounds(grid_pos):
					continue
				var index := _grid_index(grid_pos)
				var cell := _grid[index]
				if (cell & MAT_MASK) != MAT_SAND:
					continue
				if (cell & VACUUM_MASK) != 0:
					continue
				var world_pos := grid_to_world(grid_pos)
				var world_to_center := (world_pos - center) / voxel_size
				if world_to_center.length_squared() <= radius_sq:
					_grid[index] = cell | VACUUM_MASK | ACTIVE_MASK
					_grid_dirty = true
					_grid_version += 1
					tagged += 1
					if tagged >= max_count:
						break
	_vacuum_tagged_step = tagged
	if tagged > 0 and use_gpu and _gpu != null:
		_gpu.call("upload_grid", _grid)
	return tagged

func pick_voxel(ray_origin: Vector3, ray_dir: Vector3, max_dist: float) -> Variant:
	var step := voxel_size * 0.5
	var distance := 0.0
	while distance <= max_dist:
		var pos := ray_origin + ray_dir * distance
		var grid_pos := world_to_grid(pos)
		if _is_in_bounds(grid_pos) and (_grid[_grid_index(grid_pos)] & MAT_MASK) == MAT_SAND:
			return grid_pos
		distance += step
	return null

func get_debug_stats() -> Dictionary:
	var gpu_debug := {}
	if _gpu != null:
		gpu_debug = _gpu.call("get_debug_stats")
	return {
		"static_voxels": _count_voxels(),
		"grid_size": "%s" % [grid_size],
		"gpu": use_gpu,
		"sim_mode": _last_sim_mode,
		"sim_steps": _last_sim_steps,
		"sim_time_ms": "%.3f" % (float(_last_sim_time_us) / 1000.0),
		"vacuum_tagged": _vacuum_tagged_step,
		"vacuum_collected": _vacuum_collected_step,
		"vacuum_total": _vacuum_collected_total,
		"active_bricks": int(gpu_debug.get("active_bricks", 0)),
		"indirect_args": "%s" % [gpu_debug.get("indirect_args", [])],
		"occupied_bricks": int(gpu_debug.get("occupied_bricks", 0))
	}

func get_grid_data() -> PackedInt32Array:
	return _grid

func get_grid_version() -> int:
	return _grid_version

func get_grid_size() -> Vector3i:
	return grid_size

func get_grid_origin() -> Vector3i:
	return grid_origin

func get_voxel_size() -> float:
	return voxel_size

func get_brick_size() -> int:
	return brick_size

func set_use_gpu(enabled: bool) -> void:
	use_gpu = enabled
	print("[gpu] use_gpu=%s" % str(use_gpu))
	if use_gpu:
		if _gpu == null:
			_gpu = _create_gpu()
			if _gpu == null:
				push_error("[gpu] setup failed, falling back to CPU")
				use_gpu = false
				return
		else:
			_gpu.call("upload_grid", _grid)

func get_gpu_buffer_rid() -> RID:
	if _gpu == null:
		return RID()
	return _gpu.call("get_active_buffer_rid")

func get_gpu_indirection_rid() -> RID:
	if _gpu == null:
		return RID()
	return _gpu.call("get_indirection_rid")

func grid_to_world(grid_pos: Vector3i) -> Vector3:
	return Vector3(grid_pos.x, grid_pos.y, grid_pos.z) * voxel_size + Vector3.ONE * (voxel_size * 0.5)

func world_to_grid(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		floor(world_pos.x / voxel_size),
		floor(world_pos.y / voxel_size),
		floor(world_pos.z / voxel_size)
	)

func _step_sand_cpu() -> void:
	var next_grid: PackedInt32Array = _grid.duplicate()
	var moved := false
	var vacuum_radius := _vacuum_capture_radius
	var vacuum_radius_sq := vacuum_radius * vacuum_radius
	for y in range(grid_origin.y, grid_origin.y + grid_size.y):
		for x in range(grid_origin.x, grid_origin.x + grid_size.x):
			for z in range(grid_origin.z, grid_origin.z + grid_size.z):
				var cell := _get_cell(x, y, z)
				var mat := cell & MAT_MASK
				var index := _grid_index(Vector3i(x, y, z))
				if mat == MAT_WALL:
					next_grid[index] = MAT_WALL
					continue
				if mat == MAT_SAND and (cell & VACUUM_MASK) != 0:
					var pos := Vector3(x + 0.5, y + 0.5, z + 0.5)
					var dist_sq := pos.distance_squared_to(_vacuum_target_grid)
					if dist_sq <= vacuum_radius_sq * 1.5:
						next_grid[index] = MAT_EMPTY
						_vacuum_collected_step += 1
						_vacuum_collected_total += 1
						moved = true
						continue

				var incoming_data := _resolve_incoming(x, y, z, cell)
				if incoming_data["incoming"]:
					if incoming_data["vacuum"] and mat == MAT_EMPTY:
						next_grid[index] = MAT_SAND | ACTIVE_MASK | VACUUM_MASK | VACUUM_MOVED
						moved = true
						continue
					if mat == MAT_EMPTY:
						next_grid[index] = MAT_SAND | ACTIVE_MASK
						moved = true
						continue

				if mat == MAT_SAND:
					var dir := _move_dir(x, y, z, cell)
					if dir == Vector3i.ZERO:
						var is_active := _active_for(x, y, z, cell)
						var keep_vacuum := cell & VACUUM_MASK
						var moved_flag := cell & VACUUM_MOVED
						next_grid[index] = MAT_SAND | (ACTIVE_MASK if is_active else 0) | keep_vacuum | moved_flag
						continue
					next_grid[index] = MAT_EMPTY
					moved = true
					continue

				next_grid[index] = MAT_EMPTY

	if moved:
		_grid = next_grid
		_grid_dirty = true
		_grid_version += 1
		if use_gpu and _gpu != null:
			_gpu.call("upload_grid", _grid)

func _resolve_incoming(x: int, y: int, z: int, cell: int) -> Dictionary:
	var incoming_count := 0
	var incoming := false
	var incoming_vacuum := false
	var seed := _hash(x, y, z, _sim_step_id)

	var candidates := [
		{ "pos": Vector3i(x, y + 1, z), "dir": Vector3i(0, -1, 0) },
		{ "pos": Vector3i(x, y - 1, z), "dir": Vector3i(0, 1, 0) },
		{ "pos": Vector3i(x - 1, y, z), "dir": Vector3i(1, 0, 0) },
		{ "pos": Vector3i(x + 1, y, z), "dir": Vector3i(-1, 0, 0) },
		{ "pos": Vector3i(x, y, z - 1), "dir": Vector3i(0, 0, 1) },
		{ "pos": Vector3i(x, y, z + 1), "dir": Vector3i(0, 0, -1) },
		{ "pos": Vector3i(x - 1, y + 1, z), "dir": Vector3i(1, -1, 0) },
		{ "pos": Vector3i(x + 1, y + 1, z), "dir": Vector3i(-1, -1, 0) },
		{ "pos": Vector3i(x, y + 1, z - 1), "dir": Vector3i(0, -1, 1) },
		{ "pos": Vector3i(x, y + 1, z + 1), "dir": Vector3i(0, -1, -1) }
	]

	for entry in candidates:
		var src: Vector3i = entry["pos"]
		var dir: Vector3i = entry["dir"]
		if _wants_move(src.x, src.y, src.z, dir):
			incoming_count += 1
			if (seed % incoming_count) == 0:
				incoming = true
				incoming_vacuum = _is_vacuumed(src.x, src.y, src.z)

	return { "incoming": incoming, "vacuum": incoming_vacuum }

func _active_for(x: int, y: int, z: int, cell: int) -> bool:
	if (cell & MAT_MASK) != MAT_SAND:
		return false
	if (cell & VACUUM_MASK) != 0:
		return true
	if (cell & ACTIVE_MASK) != 0:
		return true
	var below := _get_cell(x, y - 1, z)
	return (below & MAT_MASK) == MAT_EMPTY

func _move_dir(x: int, y: int, z: int, cell: int) -> Vector3i:
	if (cell & MAT_MASK) != MAT_SAND:
		return Vector3i.ZERO
	if not _active_for(x, y, z, cell):
		return Vector3i.ZERO
	if (cell & VACUUM_MASK) != 0:
		return _vacuum_dir(x, y, z)
	var below := _get_cell(x, y - 1, z)
	if (below & MAT_MASK) == MAT_EMPTY:
		return Vector3i(0, -1, 0)

	var r := int(_hash(x, y, z, grid_size.x + grid_size.y + grid_size.z + _sim_step_id) & 3)
	var dx: Array[int] = [-1, 1, 0, 0]
	var dz: Array[int] = [0, 0, -1, 1]
	for i in range(4):
		var k := (i + r) & 3
		var nx: int = x + dx[k]
		var nz: int = z + dz[k]
		var diag := _get_cell(nx, y - 1, nz)
		if (diag & MAT_MASK) == MAT_EMPTY:
			return Vector3i(dx[k], -1, dz[k])

	return Vector3i.ZERO

func _vacuum_dir(x: int, y: int, z: int) -> Vector3i:
	var pos := Vector3(x + 0.5, y + 0.5, z + 0.5)
	var dir := _vacuum_target_grid - pos
	var adir := Vector3(abs(dir.x), abs(dir.y), abs(dir.z))
	var primary := Vector3i.ZERO
	var secondary := Vector3i.ZERO
	var tertiary := Vector3i.ZERO

	if adir.x >= adir.y and adir.x >= adir.z:
		primary = Vector3i(_sign(dir.x), 0, 0)
		secondary = Vector3i(0, _sign(dir.y), 0)
		tertiary = Vector3i(0, 0, _sign(dir.z))
	elif adir.y >= adir.z:
		primary = Vector3i(0, _sign(dir.y), 0)
		secondary = Vector3i(_sign(dir.x), 0, 0)
		tertiary = Vector3i(0, 0, _sign(dir.z))
	else:
		primary = Vector3i(0, 0, _sign(dir.z))
		secondary = Vector3i(_sign(dir.x), 0, 0)
		tertiary = Vector3i(0, _sign(dir.y), 0)

	var step := primary
	if (_get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY:
		return step

	step = secondary
	if (_get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY:
		return step

	step = tertiary
	if (_get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY:
		return step

	return Vector3i.ZERO

func _wants_move(src_x: int, src_y: int, src_z: int, dir: Vector3i) -> bool:
	if not _in_bounds(src_x, src_y, src_z):
		return false
	var cell := _get_cell(src_x, src_y, src_z)
	if (cell & MAT_MASK) != MAT_SAND:
		return false
	var desire := _move_dir(src_x, src_y, src_z, cell)
	return desire == dir

func _is_vacuumed(src_x: int, src_y: int, src_z: int) -> bool:
	if not _in_bounds(src_x, src_y, src_z):
		return false
	var cell := _get_cell(src_x, src_y, src_z)
	return (cell & VACUUM_MASK) != 0

func _hash(x: int, y: int, z: int, frame: int) -> int:
	var h := int(x) * 374761393
	h += int(y) * 668265263
	h += int(z) * 2246822519
	h += int(frame) * 3266489917
	h = int((h ^ (h >> 13)) * 1274126177)
	return abs(h ^ (h >> 16))

func _sign(value: float) -> int:
	if value >= 0.0:
		return 1
	return -1

func _get_cell(x: int, y: int, z: int) -> int:
	if not _in_bounds(x, y, z):
		return MAT_WALL
	return _grid[_grid_index(Vector3i(x, y, z))]

func _rebuild_static_multimesh() -> void:
	var transforms: Array[Transform3D] = []
	for x in range(grid_origin.x, grid_origin.x + grid_size.x):
		for y in range(grid_origin.y, grid_origin.y + grid_size.y):
			for z in range(grid_origin.z, grid_origin.z + grid_size.z):
				var pos := Vector3i(x, y, z)
				var cell := _grid[_grid_index(pos)]
				if (cell & MAT_MASK) != MAT_SAND:
					continue
				transforms.append(Transform3D(Basis.IDENTITY, grid_to_world(pos)))
	_static_multimesh.instance_count = transforms.size()
	for i in transforms.size():
		_static_multimesh.set_instance_transform(i, transforms[i])

func _is_in_bounds(grid_pos: Vector3i) -> bool:
	return _in_bounds(grid_pos.x, grid_pos.y, grid_pos.z)

func _in_bounds(x: int, y: int, z: int) -> bool:
	return x >= grid_origin.x and y >= grid_origin.y and z >= grid_origin.z \
		and x < grid_origin.x + grid_size.x and y < grid_origin.y + grid_size.y and z < grid_origin.z + grid_size.z

func _grid_index(grid_pos: Vector3i) -> int:
	var local := grid_pos - grid_origin
	return (local.z * grid_size.y + local.y) * grid_size.x + local.x

func _count_voxels() -> int:
	var count := 0
	for value in _grid:
		if (value & MAT_MASK) == MAT_SAND:
			count += 1
	return count
