extends Node

const GRID_SIZE := 128
const BRICK_SIZE := 8
const BRICK_COUNT := GRID_SIZE / BRICK_SIZE

@export var camera_path: NodePath = NodePath("HelloCamera")
@export var output_mesh_path: NodePath = NodePath("HelloCamera/RaymarchQuad")
@export var camera_target := Vector3.ZERO
@export var use_debug_shader := true

const RAYMARCH_SHADER: Shader = preload("res://shaders/voxel_raymarch.gdshader")
const DEBUG_SHADER: Shader = preload("res://shaders/debug_uv.gdshader")

var _camera: Camera3D
var _shader_material: ShaderMaterial
var _debug_mode := 0

func _ready() -> void:
	_camera = get_node(camera_path) as Camera3D
	var quad := get_node(output_mesh_path) as MeshInstance3D
	_shader_material = quad.material_override as ShaderMaterial
	if _shader_material == null:
		_shader_material = ShaderMaterial.new()
		quad.material_override = _shader_material
	_shader_material.shader = DEBUG_SHADER if use_debug_shader else RAYMARCH_SHADER
	print("VoxelRenderer shader bound: ", _shader_material.shader)

	var indirection_tex := _build_indirection_texture()
	var atlas_tex := _build_atlas_texture()

	_shader_material.set_shader_parameter("indirection_tex", indirection_tex)
	_shader_material.set_shader_parameter("atlas_tex", atlas_tex)
	_shader_material.set_shader_parameter("grid_min", Vector3(-64.0, -64.0, -64.0))
	_shader_material.set_shader_parameter("grid_max", Vector3(64.0, 64.0, 64.0))
	_shader_material.set_shader_parameter("grid_size", Vector3i(GRID_SIZE, GRID_SIZE, GRID_SIZE))
	_shader_material.set_shader_parameter("brick_counts", Vector3i(BRICK_COUNT, BRICK_COUNT, BRICK_COUNT))
	_shader_material.set_shader_parameter("brick_size", BRICK_SIZE)
	_shader_material.set_shader_parameter("debug_mode", _debug_mode)

	set_process(true)

func _process(_delta: float) -> void:
	var basis := _camera.global_transform.basis
	_shader_material.set_shader_parameter("cam_basis", basis)
	_shader_material.set_shader_parameter("cam_origin", _camera.global_transform.origin)
	_shader_material.set_shader_parameter("cam_target", camera_target)
	_shader_material.set_shader_parameter("cam_fov", _camera.fov)
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.y > 0.0:
		_shader_material.set_shader_parameter("cam_aspect", viewport_size.x / viewport_size.y)
	_shader_material.set_shader_parameter("debug_mode", 1)
	_shader_material.set_shader_parameter("cam_debug", _camera.global_transform.origin * 0.02 + Vector3(0.5, 0.5, 0.5))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
		_debug_mode = 1 - _debug_mode
		_shader_material.set_shader_parameter("debug_mode", _debug_mode)

func _build_indirection_texture() -> ImageTexture3D:
	var images: Array[Image] = []
	for z in range(BRICK_COUNT):
		var img := Image.create(BRICK_COUNT, BRICK_COUNT, false, Image.FORMAT_RF)
		for y in range(BRICK_COUNT):
			for x in range(BRICK_COUNT):
				var index := float(x + y * BRICK_COUNT + z * BRICK_COUNT * BRICK_COUNT)
				var max_index := float(BRICK_COUNT * BRICK_COUNT * BRICK_COUNT - 1)
				var normalized := index / max_index
				img.set_pixel(x, y, Color(normalized, 0.0, 0.0, 1.0))
		images.append(img)

	var tex := ImageTexture3D.new()
	var err := tex.create(Image.FORMAT_RF, BRICK_COUNT, BRICK_COUNT, BRICK_COUNT, false, images)
	if err != OK:
		push_error("Failed to create indirection texture: %s" % err)
	return tex

func _build_atlas_texture() -> ImageTexture3D:
	var images: Array[Image] = []
	for z in range(GRID_SIZE):
		var img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_R8)
		for y in range(GRID_SIZE):
			for x in range(GRID_SIZE):
				var filled := x >= 32 and x < 96 and y >= 32 and y < 96 and z >= 32 and z < 96
				var value := 255 if filled else 0
				img.set_pixel(x, y, Color8(value, 0, 0, 255))
		images.append(img)

	var tex := ImageTexture3D.new()
	var err := tex.create(Image.FORMAT_R8, GRID_SIZE, GRID_SIZE, GRID_SIZE, false, images)
	if err != OK:
		push_error("Failed to create atlas texture: %s" % err)
	return tex
