extends Node

class_name VoxelCompute
const LOCAL_SIZE_X := 8
const LOCAL_SIZE_Y := 8
const LOCAL_SIZE_Z := 8

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _occ_shader: RID
var _occ_pipeline: RID
var _active_shader: RID
var _active_pipeline: RID
var _args_shader: RID
var _args_pipeline: RID

var _indirection: RID
var _atlas_a: RID
var _atlas_b: RID
var _params: RID
var _counts: RID
var _occ_buffer: RID
var _occ_params: RID
var _active_list: RID
var _active_count: RID
var _indirect_args: RID
var _readback_active_count := 0
var _readback_indirect_args := PackedInt32Array([0, 0, 0])
var _readback_occ_count := 0

var _uniform_set_a: RID
var _uniform_set_b: RID
var _occ_uniform_set_a: RID
var _occ_uniform_set_b: RID
var _active_uniform_set: RID
var _args_uniform_set: RID

var _using_a := true
var _grid_size := Vector3i.ZERO
var _brick_size := 8
var _brick_dims := Vector3i.ZERO
var _brick_volume := 0
var _last_counts := {"moved": 0, "deleted": 0}
var _readback_enabled := false

func setup(size: Vector3i, brick_size: int = 8) -> bool:
	_grid_size = size
	_brick_size = max(brick_size, 1)
	_brick_dims = Vector3i(
		int(ceil(float(size.x) / float(_brick_size))),
		int(ceil(float(size.y) / float(_brick_size))),
		int(ceil(float(size.z) / float(_brick_size)))
	)
	_brick_volume = _brick_size * _brick_size * _brick_size
	_rd = RenderingServer.get_rendering_device()

	var sim_file := load("res://assets/voxel_compute.glsl") as RDShaderFile
	if sim_file == null:
		push_error("[gpu] failed to load voxel_compute.glsl")
		return false
	var sim_spirv := sim_file.get_spirv()
	if sim_spirv == null:
		push_error("[gpu] failed to get SPIR-V from sim shader")
		return false
	if not sim_spirv.compile_error_compute.is_empty():
		push_error("[gpu] sim shader compile error: %s" % sim_spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(sim_spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	if _pipeline == RID():
		push_error("[gpu] failed to create sim pipeline")
		return false

	var occ_file := load("res://assets/voxel_occupancy.glsl") as RDShaderFile
	var occ_spirv := occ_file.get_spirv()
	if not occ_spirv.compile_error_compute.is_empty():
		push_error("[gpu] occupancy shader compile error: %s" % occ_spirv.compile_error_compute)
		return false
	_occ_shader = _rd.shader_create_from_spirv(occ_spirv)
	_occ_pipeline = _rd.compute_pipeline_create(_occ_shader)

	var active_file := load("res://assets/voxel_active_list.glsl") as RDShaderFile
	var active_spirv := active_file.get_spirv()
	if not active_spirv.compile_error_compute.is_empty():
		push_error("[gpu] active list shader compile error: %s" % active_spirv.compile_error_compute)
		return false
	_active_shader = _rd.shader_create_from_spirv(active_spirv)
	_active_pipeline = _rd.compute_pipeline_create(_active_shader)

	var args_file := load("res://assets/voxel_indirect_args.glsl") as RDShaderFile
	var args_spirv := args_file.get_spirv()
	if not args_spirv.compile_error_compute.is_empty():
		push_error("[gpu] indirect args shader compile error: %s" % args_spirv.compile_error_compute)
		return false
	_args_shader = _rd.shader_create_from_spirv(args_spirv)
	_args_pipeline = _rd.compute_pipeline_create(_args_shader)

	var brick_count := _brick_dims.x * _brick_dims.y * _brick_dims.z
	var atlas_count := brick_count * _brick_volume
	var data := PackedInt32Array()
	data.resize(atlas_count)
	var bytes := data.to_byte_array()
	_atlas_a = _rd.storage_buffer_create(bytes.size(), bytes)
	_atlas_b = _rd.storage_buffer_create(bytes.size(), bytes)

	var indirection := PackedInt32Array()
	indirection.resize(brick_count)
	for i in brick_count:
		indirection[i] = i + 1
	_indirection = _rd.storage_buffer_create(indirection.to_byte_array().size(), indirection.to_byte_array())

	var params := _pack_params(0, Vector3.ZERO, 1.0)
	_params = _rd.storage_buffer_create(params.size(), params)

	var counts := PackedInt32Array([0, 0])
	_counts = _rd.storage_buffer_create(counts.to_byte_array().size(), counts.to_byte_array())

	var occ_bytes := PackedByteArray()
	_occ_buffer = _rd.storage_buffer_create(brick_count * 4, occ_bytes)
	_occ_params = _rd.storage_buffer_create(4 * 8, PackedByteArray())
	_update_occ_params()

	_active_list = _rd.storage_buffer_create(brick_count * 4, PackedByteArray())
	_active_count = _rd.storage_buffer_create(4, PackedByteArray())
	var args_bytes := PackedByteArray()
	args_bytes.resize(12)
	_indirect_args = _rd.storage_buffer_create(
		12,
		args_bytes,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
	)

	_uniform_set_a = _create_uniform_set(_atlas_a, _atlas_b)
	_uniform_set_b = _create_uniform_set(_atlas_b, _atlas_a)
	_occ_uniform_set_a = _create_occ_uniform_set(_atlas_a)
	_occ_uniform_set_b = _create_occ_uniform_set(_atlas_b)
	_active_uniform_set = _create_active_uniform_set()
	_args_uniform_set = _create_args_uniform_set()

	if _uniform_set_a == RID() or _uniform_set_b == RID():
		push_error("[gpu] failed to create sim uniform sets")
		return false
	return true

func upload_grid(grid: PackedInt32Array) -> void:
	var atlas := _grid_to_atlas(grid)
	var bytes := atlas.to_byte_array()
	_rd.buffer_update(_atlas_a, 0, bytes.size(), bytes)
	_rd.buffer_update(_atlas_b, 0, bytes.size(), bytes)

func step_inplace(step_id: int, vacuum_pos: Vector3, vacuum_radius: float) -> void:
	var params := _pack_params(step_id, vacuum_pos, vacuum_radius)
	_rd.buffer_update(_params, 0, params.size(), params)
	if _readback_enabled:
		_reset_counts()
	_reset_active_count()

	RenderingServer.call_on_render_thread(_dispatch_sim)

func get_active_buffer_rid() -> RID:
	if _using_a:
		return _atlas_a
	return _atlas_b

func get_indirection_rid() -> RID:
	return _indirection

func download_grid() -> PackedInt32Array:
	var buffer := _atlas_b
	if _using_a:
		buffer = _atlas_a
	var atlas := _rd.buffer_get_data(buffer).to_int32_array()
	return _atlas_to_grid(atlas)

func _create_uniform_set(in_buffer: RID, out_buffer: RID) -> RID:
	var uniforms: Array[RDUniform] = []

	var ind_uniform := RDUniform.new()
	ind_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ind_uniform.binding = 0
	ind_uniform.add_id(_indirection)
	uniforms.append(ind_uniform)

	var in_uniform := RDUniform.new()
	in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	in_uniform.binding = 1
	in_uniform.add_id(in_buffer)
	uniforms.append(in_uniform)

	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out_uniform.binding = 2
	out_uniform.add_id(out_buffer)
	uniforms.append(out_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(_params)
	uniforms.append(params_uniform)

	var counts_uniform := RDUniform.new()
	counts_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	counts_uniform.binding = 4
	counts_uniform.add_id(_counts)
	uniforms.append(counts_uniform)

	var list_uniform := RDUniform.new()
	list_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	list_uniform.binding = 5
	list_uniform.add_id(_active_list)
	uniforms.append(list_uniform)

	return _rd.uniform_set_create(uniforms, _shader, 0)

func _create_occ_uniform_set(atlas: RID) -> RID:
	var uniforms: Array[RDUniform] = []

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	atlas_uniform.binding = 0
	atlas_uniform.add_id(atlas)
	uniforms.append(atlas_uniform)

	var occ_uniform := RDUniform.new()
	occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	occ_uniform.binding = 1
	occ_uniform.add_id(_occ_buffer)
	uniforms.append(occ_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(_occ_params)
	uniforms.append(params_uniform)

	return _rd.uniform_set_create(uniforms, _occ_shader, 0)

func _create_active_uniform_set() -> RID:
	var uniforms: Array[RDUniform] = []

	var occ_uniform := RDUniform.new()
	occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	occ_uniform.binding = 0
	occ_uniform.add_id(_occ_buffer)
	uniforms.append(occ_uniform)

	var list_uniform := RDUniform.new()
	list_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	list_uniform.binding = 1
	list_uniform.add_id(_active_list)
	uniforms.append(list_uniform)

	var count_uniform := RDUniform.new()
	count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	count_uniform.binding = 2
	count_uniform.add_id(_active_count)
	uniforms.append(count_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(_occ_params)
	uniforms.append(params_uniform)

	return _rd.uniform_set_create(uniforms, _active_shader, 0)

func _create_args_uniform_set() -> RID:
	var uniforms: Array[RDUniform] = []

	var count_uniform := RDUniform.new()
	count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	count_uniform.binding = 0
	count_uniform.add_id(_active_count)
	uniforms.append(count_uniform)

	var args_uniform := RDUniform.new()
	args_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	args_uniform.binding = 1
	args_uniform.add_id(_indirect_args)
	uniforms.append(args_uniform)

	return _rd.uniform_set_create(uniforms, _args_shader, 0)

func _pack_params(step_id: int, vacuum_pos: Vector3, vacuum_radius: float) -> PackedByteArray:
	var ints := PackedInt32Array([
		_grid_size.x, _grid_size.y, _grid_size.z, step_id,
		_brick_dims.x, _brick_dims.y, _brick_dims.z, _brick_size
	])
	var floats := PackedFloat32Array([vacuum_pos.x, vacuum_pos.y, vacuum_pos.z, vacuum_radius])
	var bytes := ints.to_byte_array()
	bytes.append_array(floats.to_byte_array())
	return bytes

func _update_occ_params() -> void:
	var occ_params := PackedInt32Array([
		_grid_size.x, _grid_size.y, _grid_size.z, 0,
		_brick_dims.x, _brick_dims.y, _brick_dims.z, _brick_size
	])
	var bytes := occ_params.to_byte_array()
	_rd.buffer_update(_occ_params, 0, bytes.size(), bytes)

func _reset_counts() -> void:
	var counts := PackedInt32Array([0, 0])
	var bytes := counts.to_byte_array()
	_rd.buffer_update(_counts, 0, bytes.size(), bytes)

func _read_counts() -> void:
	var data := _rd.buffer_get_data(_counts).to_int32_array()
	if data.size() >= 2:
		_last_counts["moved"] = data[0]
		_last_counts["deleted"] = data[1]

func get_last_counts() -> Dictionary:
	return _last_counts.duplicate(true)

func get_debug_stats() -> Dictionary:
	return {
		"active_bricks": _readback_active_count,
		"indirect_args": _readback_indirect_args.duplicate(),
		"occupied_bricks": _readback_occ_count
	}

func set_readback_enabled(enabled: bool) -> void:
	_readback_enabled = enabled

func _groups(size: int, local: int) -> int:
	return int(ceil(float(size) / float(local)))

func _grid_to_atlas(grid: PackedInt32Array) -> PackedInt32Array:
	var brick_count := _brick_dims.x * _brick_dims.y * _brick_dims.z
	var atlas_count := brick_count * _brick_volume
	var atlas := PackedInt32Array()
	atlas.resize(atlas_count)
	for z in range(_grid_size.z):
		for y in range(_grid_size.y):
			for x in range(_grid_size.x):
				var grid_index := (z * _grid_size.y + y) * _grid_size.x + x
				var brick_x := x / _brick_size
				var brick_y := y / _brick_size
				var brick_z := z / _brick_size
				var brick_index := (brick_z * _brick_dims.y + brick_y) * _brick_dims.x + brick_x
				var local_x := x % _brick_size
				var local_y := y % _brick_size
				var local_z := z % _brick_size
				var local_index := (local_z * _brick_size + local_y) * _brick_size + local_x
				var atlas_index := brick_index * _brick_volume + local_index
				atlas[atlas_index] = grid[grid_index]
	return atlas

func _atlas_to_grid(atlas: PackedInt32Array) -> PackedInt32Array:
	var grid_count := _grid_size.x * _grid_size.y * _grid_size.z
	var grid := PackedInt32Array()
	grid.resize(grid_count)
	for z in range(_grid_size.z):
		for y in range(_grid_size.y):
			for x in range(_grid_size.x):
				var grid_index := (z * _grid_size.y + y) * _grid_size.x + x
				var brick_x := x / _brick_size
				var brick_y := y / _brick_size
				var brick_z := z / _brick_size
				var brick_index := (brick_z * _brick_dims.y + brick_y) * _brick_dims.x + brick_x
				var local_x := x % _brick_size
				var local_y := y % _brick_size
				var local_z := z % _brick_size
				var local_index := (local_z * _brick_size + local_y) * _brick_size + local_x
				var atlas_index := brick_index * _brick_volume + local_index
				grid[grid_index] = atlas[atlas_index]
	return grid

func _reset_active_count() -> void:
	var data := PackedInt32Array([0])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_active_count, 0, bytes.size(), bytes)

func _dispatch_sim() -> void:
	if _rd == null:
		return
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _occ_pipeline)
	var occ_set := _occ_uniform_set_a
	if not _using_a:
		occ_set = _occ_uniform_set_b
	_rd.compute_list_bind_uniform_set(compute_list, occ_set, 0)
	_rd.compute_list_dispatch(
		compute_list,
		_groups(_brick_dims.x, 4),
		_groups(_brick_dims.y, 4),
		_groups(_brick_dims.z, 4)
	)

	_rd.compute_list_bind_compute_pipeline(compute_list, _active_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _active_uniform_set, 0)
	_rd.compute_list_dispatch(
		compute_list,
		_groups(_brick_dims.x, 4),
		_groups(_brick_dims.y, 4),
		_groups(_brick_dims.z, 4)
	)
	_rd.compute_list_end()

	var sim_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(sim_list, _args_pipeline)
	_rd.compute_list_bind_uniform_set(sim_list, _args_uniform_set, 0)
	_rd.compute_list_dispatch(sim_list, 1, 1, 1)

	_rd.compute_list_bind_compute_pipeline(sim_list, _pipeline)
	var active_set := _uniform_set_a
	if not _using_a:
		active_set = _uniform_set_b
	_rd.compute_list_bind_uniform_set(sim_list, active_set, 0)
	_rd.compute_list_dispatch_indirect(sim_list, _indirect_args, 0)
	_rd.compute_list_end()

	if _readback_enabled:
		_read_counts()
		_read_debug()
	_using_a = not _using_a

func _read_debug() -> void:
	var active_data := _rd.buffer_get_data(_active_count).to_int32_array()
	if active_data.size() >= 1:
		_readback_active_count = active_data[0]
	var args_data := _rd.buffer_get_data(_indirect_args).to_int32_array()
	if args_data.size() >= 3:
		_readback_indirect_args = PackedInt32Array([args_data[0], args_data[1], args_data[2]])
	var occ_data := _rd.buffer_get_data(_occ_buffer).to_int32_array()
	var occ_sum := 0
	for value in occ_data:
		if value != 0:
			occ_sum += 1
	_readback_occ_count = occ_sum
