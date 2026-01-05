extends Node

@export var camera_path: NodePath = NodePath("../OrbitRig/Camera3D")
@export var output_mesh_path: NodePath = NodePath("../OrbitRig/Camera3D/RaymarchQuad")
@export var orbit_rig_path: NodePath = NodePath("../OrbitRig")

const DISPLAY_SHADER: Shader = preload("res://shaders/compute_display.gdshader")
const COMPUTE_SHADER_PATH := "res://shaders/compute_raymarch.glsl"

var _camera: Camera3D
var _quad: MeshInstance3D
var _orbit_rig: Node
var _display_material: ShaderMaterial

var _rd: RenderingDevice
var _compute_shader_rid: RID
var _pipeline_rid: RID
var _uniform_set_rid: RID
var _output_texture_rid: RID
var _output_texture: Texture2DRD
var _output_size := Vector2i.ZERO

func _ready() -> void:
    _camera = get_node_or_null(camera_path) as Camera3D
    _quad = get_node_or_null(output_mesh_path) as MeshInstance3D
    _orbit_rig = get_node_or_null(orbit_rig_path)

    if _camera == null or _quad == null:
        push_error("VoxelRenderer missing camera or quad.")
        return

    _display_material = ShaderMaterial.new()
    _display_material.shader = DISPLAY_SHADER
    _quad.material_override = _display_material
    _quad.set_surface_override_material(0, _display_material)

    _rd = RenderingServer.get_rendering_device()
    if _rd == null:
        push_error("RenderingDevice unavailable.")
        return

    _compile_compute_shader()
    _resize_output_texture()

func _process(_delta: float) -> void:
    if _rd == null:
        return

    var viewport_size := get_viewport().get_visible_rect().size
    var target_size := Vector2i(max(1, int(viewport_size.x)), max(1, int(viewport_size.y)))
    if target_size != _output_size:
        _resize_output_texture()

    _dispatch_compute()

func _compile_compute_shader() -> void:
    if _compute_shader_rid.is_valid():
        _rd.free_rid(_compute_shader_rid)
    if _pipeline_rid.is_valid():
        _rd.free_rid(_pipeline_rid)

    var source_text := FileAccess.get_file_as_string(COMPUTE_SHADER_PATH)
    if source_text.is_empty():
        push_error("Compute shader source missing: %s" % COMPUTE_SHADER_PATH)
        return

    source_text = source_text.replace("#[compute]", "")
    var shader_source := RDShaderSource.new()
    shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)

    var spirv := _rd.shader_compile_spirv_from_source(shader_source)
    _compute_shader_rid = _rd.shader_create_from_spirv(spirv)
    _pipeline_rid = _rd.compute_pipeline_create(_compute_shader_rid)

func _resize_output_texture() -> void:
    if _output_texture_rid.is_valid():
        _rd.free_rid(_output_texture_rid)
    if _uniform_set_rid.is_valid():
        _rd.free_rid(_uniform_set_rid)

    var viewport_size := get_viewport().get_visible_rect().size
    _output_size = Vector2i(max(1, int(viewport_size.x)), max(1, int(viewport_size.y)))

    var format := RDTextureFormat.new()
    format.width = _output_size.x
    format.height = _output_size.y
    format.depth = 1
    format.mipmaps = 1
    format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
    format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

    var view := RDTextureView.new()
    _output_texture_rid = _rd.texture_create(format, view, [])

    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    uniform.binding = 0
    uniform.add_id(_output_texture_rid)
    _uniform_set_rid = _rd.uniform_set_create([uniform], _compute_shader_rid, 0)

    _output_texture = Texture2DRD.new()
    _output_texture.texture_rd_rid = _output_texture_rid
    _display_material.set_shader_parameter("compute_tex", _output_texture)

func _dispatch_compute() -> void:
    if not (_pipeline_rid.is_valid() and _uniform_set_rid.is_valid()):
        return

    var local_size := 8
    var groups_x := int(ceil(_output_size.x / float(local_size)))
    var groups_y := int(ceil(_output_size.y / float(local_size)))

    var compute_list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(compute_list, _pipeline_rid)
    _rd.compute_list_bind_uniform_set(compute_list, _uniform_set_rid, 0)
    _rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
    _rd.compute_list_end()
    _rd.submit()
    _rd.sync()

func _exit_tree() -> void:
    if _rd:
        if _uniform_set_rid.is_valid():
            _rd.free_rid(_uniform_set_rid)
        if _pipeline_rid.is_valid():
            _rd.free_rid(_pipeline_rid)
        if _compute_shader_rid.is_valid():
            _rd.free_rid(_compute_shader_rid)
        if _output_texture_rid.is_valid():
            _rd.free_rid(_output_texture_rid)
