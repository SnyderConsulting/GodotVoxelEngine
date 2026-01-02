extends Node
class_name VoxelRenderer

@export var max_distance := 64.0
@export var render_scale := 0.5
@export var brick_size := 8

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _uniform_set: RID
var _grid_buffer: RID
var _indirection_buffer: RID
var _params_buffer: RID
var _occ_shader: RID
var _occ_pipeline: RID
var _occ_uniform_set: RID
var _occ_buffer: RID
var _occ_params_buffer: RID
var _output_tex: RID
var _texture: Texture2DRD
var _texture_rect: TextureRect
var _canvas_layer: CanvasLayer
var _grid_buffer_size := 0
var _indirection_buffer_size := 0
var _occ_buffer_size := 0
var _occ_grid_buffer_cache: RID

var _world: Node = null
var _camera: Camera3D = null
var _grid_version := -1
var _viewport_size := Vector2i.ZERO
var _render_size := Vector2i.ZERO
var _grid_size_cache := Vector3i.ZERO
var _brick_dims_cache := Vector3i.ZERO
var _brick_size_cache := 0

func _ready() -> void:
	_world = get_parent().get_node("World")
	_camera = get_parent().get_node("Player/Camera3D")
	if _world != null:
		brick_size = int(_world.call("get_brick_size"))
	_rd = RenderingServer.get_rendering_device()
	_setup_output()
	_setup_shader()

func _process(_delta: float) -> void:
	if _world == null or _camera == null:
		return
	var viewport := get_viewport()
	if viewport != null:
		var size := viewport.get_visible_rect().size
		var new_size := Vector2i(int(size.x), int(size.y))
		if new_size != _viewport_size:
			_viewport_size = new_size
			_setup_output()

	var rid: RID = _world.call("get_gpu_buffer_rid")
	var indirection: RID = _world.call("get_gpu_indirection_rid")
	if rid != RID() and indirection != RID():
		if rid != _grid_buffer or indirection != _indirection_buffer:
			_grid_buffer = rid
			_indirection_buffer = indirection
			_update_occ_resources()
			_update_uniform_set()
	else:
		var version := int(_world.call("get_grid_version"))
		if version != _grid_version:
			_grid_version = version
			var grid: PackedInt32Array = _world.call("get_grid_data")
			_update_grid_buffer(grid)

	_update_params()
	RenderingServer.call_on_render_thread(_dispatch)

func _setup_shader() -> void:
	var shader_file := load("res://assets/voxel_raymarch.glsl") as RDShaderFile
	var spirv := shader_file.get_spirv()
	if not spirv.compile_error_compute.is_empty():
		push_error("[render] shader compile error: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)

	var occ_file := load("res://assets/voxel_occupancy.glsl") as RDShaderFile
	var occ_spirv := occ_file.get_spirv()
	if not occ_spirv.compile_error_compute.is_empty():
		push_error("[render] occupancy shader compile error: %s" % occ_spirv.compile_error_compute)
		return
	_occ_shader = _rd.shader_create_from_spirv(occ_spirv)
	_occ_pipeline = _rd.compute_pipeline_create(_occ_shader)

	_params_buffer = _rd.storage_buffer_create(16 * 9, PackedByteArray())
	_occ_params_buffer = _rd.storage_buffer_create(4 * 8, PackedByteArray())
	_update_grid_buffer(PackedInt32Array())
	_update_uniform_set()

func _setup_output() -> void:
	if _viewport_size.x <= 0 or _viewport_size.y <= 0:
		_viewport_size = Vector2i(1280, 720)
	_render_size = Vector2i(
		max(1, int(float(_viewport_size.x) * render_scale)),
		max(1, int(float(_viewport_size.y) * render_scale))
	)

	var format := RDTextureFormat.new()
	format.width = _render_size.x
	format.height = _render_size.y
	format.depth = 1
	format.mipmaps = 1
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

	var view := RDTextureView.new()
	_output_tex = _rd.texture_create(format, view, [])
	_texture = Texture2DRD.new()
	_texture.texture_rd_rid = _output_tex

	if _canvas_layer == null:
		_canvas_layer = CanvasLayer.new()
		_canvas_layer.layer = 10
		add_child(_canvas_layer)

	if _texture_rect == null:
		_texture_rect = TextureRect.new()
		_texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_texture_rect.anchor_left = 0.0
		_texture_rect.anchor_top = 0.0
		_texture_rect.anchor_right = 1.0
		_texture_rect.anchor_bottom = 1.0
		_canvas_layer.add_child(_texture_rect)

	_texture_rect.texture = _texture
	_update_uniform_set()

func _update_grid_buffer(grid: PackedInt32Array) -> void:
	var grid_size: Vector3i = _world.call("get_grid_size")
	var expected := grid_size.x * grid_size.y * grid_size.z
	if grid.size() != expected:
		var filled := PackedInt32Array()
		filled.resize(max(1, expected))
		for i in filled.size():
			filled[i] = 0
		grid = filled
	var brickmap: Dictionary = _grid_to_brickmap(grid)
	var atlas_bytes: PackedByteArray = brickmap["atlas"]
	var ind_bytes: PackedByteArray = brickmap["indirection"]
	if _grid_buffer == RID() or atlas_bytes.size() != _grid_buffer_size:
		_grid_buffer = _rd.storage_buffer_create(atlas_bytes.size(), atlas_bytes)
		_grid_buffer_size = atlas_bytes.size()
	else:
		_rd.buffer_update(_grid_buffer, 0, atlas_bytes.size(), atlas_bytes)
	if _indirection_buffer == RID() or ind_bytes.size() != _indirection_buffer_size:
		_indirection_buffer = _rd.storage_buffer_create(ind_bytes.size(), ind_bytes)
		_indirection_buffer_size = ind_bytes.size()
	else:
		_rd.buffer_update(_indirection_buffer, 0, ind_bytes.size(), ind_bytes)
	_update_occ_resources()
	_update_uniform_set()

func _update_uniform_set() -> void:
	if _shader == RID() or _grid_buffer == RID() or _indirection_buffer == RID() or _params_buffer == RID() or _output_tex == RID() or _occ_buffer == RID():
		return

	var uniforms: Array[RDUniform] = []
	var ind_uniform := RDUniform.new()
	ind_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	ind_uniform.binding = 0
	ind_uniform.add_id(_indirection_buffer)
	uniforms.append(ind_uniform)

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	atlas_uniform.binding = 1
	atlas_uniform.add_id(_grid_buffer)
	uniforms.append(atlas_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(_params_buffer)
	uniforms.append(params_uniform)

	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	out_uniform.binding = 3
	out_uniform.add_id(_output_tex)
	uniforms.append(out_uniform)

	var occ_uniform := RDUniform.new()
	occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	occ_uniform.binding = 4
	occ_uniform.add_id(_occ_buffer)
	uniforms.append(occ_uniform)

	_uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)

func _update_params() -> void:
	var grid_size: Vector3i = _world.call("get_grid_size")
	var grid_origin: Vector3i = _world.call("get_grid_origin")
	var voxel_size: float = float(_world.call("get_voxel_size"))
	_update_occ_resources(grid_size)

	var cam_basis := _camera.global_transform.basis
	var cam_forward := -cam_basis.z

	var tan_half_fov := tan(deg_to_rad(_camera.fov) * 0.5)
	var aspect: float = float(_render_size.x) / max(1.0, float(_render_size.y))

	var brick_dims := _brick_dims_cache
	var params := PackedFloat32Array([
		float(grid_size.x), float(grid_size.y), float(grid_size.z), 0.0,
		float(grid_origin.x), float(grid_origin.y), float(grid_origin.z), 0.0,
		_camera.global_position.x, _camera.global_position.y, _camera.global_position.z, 0.0,
		cam_basis.x.x, cam_basis.x.y, cam_basis.x.z, 0.0,
		cam_basis.y.x, cam_basis.y.y, cam_basis.y.z, 0.0,
		cam_forward.x, cam_forward.y, cam_forward.z, 0.0,
		float(_render_size.x), float(_render_size.y), tan_half_fov, aspect,
		voxel_size, max_distance, 0.0, 0.0,
		float(brick_dims.x), float(brick_dims.y), float(brick_dims.z), float(_brick_size_cache)
	])

	var bytes := params.to_byte_array()
	_rd.buffer_update(_params_buffer, 0, bytes.size(), bytes)

func _dispatch() -> void:
	if _pipeline == RID() or _uniform_set == RID() or _occ_pipeline == RID() or _occ_uniform_set == RID():
		return
	var groups_x := int(ceil(float(_render_size.x) / 8.0))
	var groups_y := int(ceil(float(_render_size.y) / 8.0))
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _occ_pipeline)
	_rd.compute_list_bind_uniform_set(list, _occ_uniform_set, 0)
	var occ_groups_x := int(ceil(float(_brick_dims_cache.x) / 4.0))
	var occ_groups_y := int(ceil(float(_brick_dims_cache.y) / 4.0))
	var occ_groups_z := int(ceil(float(_brick_dims_cache.z) / 4.0))
	_rd.compute_list_dispatch(list, occ_groups_x, occ_groups_y, occ_groups_z)

	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
	_rd.compute_list_dispatch(list, groups_x, groups_y, 1)
	_rd.compute_list_end()

func _update_occ_resources(grid_size: Vector3i = _grid_size_cache) -> void:
	if grid_size == Vector3i.ZERO:
		return
	if brick_size <= 0:
		brick_size = 1
	var dims := Vector3i(
		int(ceil(float(grid_size.x) / float(brick_size))),
		int(ceil(float(grid_size.y) / float(brick_size))),
		int(ceil(float(grid_size.z) / float(brick_size)))
	)
	var size_changed: bool = grid_size != _grid_size_cache or dims != _brick_dims_cache or brick_size != _brick_size_cache
	_grid_size_cache = grid_size
	_brick_dims_cache = dims
	_brick_size_cache = brick_size

	var occ_count: int = max(1, dims.x * dims.y * dims.z)
	var occ_bytes: int = occ_count * 4
	if _occ_buffer == RID() or occ_bytes != _occ_buffer_size:
		_occ_buffer = _rd.storage_buffer_create(occ_bytes, PackedByteArray())
		_occ_buffer_size = occ_bytes

	if size_changed:
		var occ_params := PackedInt32Array([
			grid_size.x, grid_size.y, grid_size.z, 0,
			dims.x, dims.y, dims.z, brick_size
		])
		var bytes := occ_params.to_byte_array()
		_rd.buffer_update(_occ_params_buffer, 0, bytes.size(), bytes)
	_update_occ_uniform_set()
	_update_uniform_set()

func _update_occ_uniform_set() -> void:
	if _occ_shader == RID() or _grid_buffer == RID() or _occ_buffer == RID() or _occ_params_buffer == RID():
		return
	if _grid_buffer == _occ_grid_buffer_cache and _occ_uniform_set != RID():
		return
	var uniforms: Array[RDUniform] = []
	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	atlas_uniform.binding = 0
	atlas_uniform.add_id(_grid_buffer)
	uniforms.append(atlas_uniform)

	var occ_uniform := RDUniform.new()
	occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	occ_uniform.binding = 1
	occ_uniform.add_id(_occ_buffer)
	uniforms.append(occ_uniform)

	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(_occ_params_buffer)
	uniforms.append(params_uniform)

	_occ_uniform_set = _rd.uniform_set_create(uniforms, _occ_shader, 0)
	_occ_grid_buffer_cache = _grid_buffer

func _grid_to_brickmap(grid: PackedInt32Array) -> Dictionary:
	var grid_size: Vector3i = _world.call("get_grid_size")
	var brick: int = max(brick_size, 1)
	var dims: Vector3i = Vector3i(
		int(ceil(float(grid_size.x) / float(brick))),
		int(ceil(float(grid_size.y) / float(brick))),
		int(ceil(float(grid_size.z) / float(brick)))
	)
	var brick_volume: int = brick * brick * brick
	var brick_count: int = dims.x * dims.y * dims.z
	var atlas_count: int = brick_count * brick_volume

	var atlas := PackedInt32Array()
	atlas.resize(atlas_count)
	for z in range(grid_size.z):
		for y in range(grid_size.y):
			for x in range(grid_size.x):
				var grid_index: int = (z * grid_size.y + y) * grid_size.x + x
				var brick_x: int = x / brick
				var brick_y: int = y / brick
				var brick_z: int = z / brick
				var brick_index: int = (brick_z * dims.y + brick_y) * dims.x + brick_x
				var local_x: int = x % brick
				var local_y: int = y % brick
				var local_z: int = z % brick
				var local_index: int = (local_z * brick + local_y) * brick + local_x
				var atlas_index: int = brick_index * brick_volume + local_index
				atlas[atlas_index] = grid[grid_index]

	var indirection := PackedInt32Array()
	indirection.resize(brick_count)
	for i in brick_count:
		indirection[i] = i + 1

	return {
		"atlas": atlas.to_byte_array(),
		"indirection": indirection.to_byte_array()
	}
