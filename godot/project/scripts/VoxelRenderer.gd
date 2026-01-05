extends Node

@export var quad_path: NodePath
@export var width := 512
@export var height := 512

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _texture_rid: RID
var _ubo_rid: RID
var _uniform_set_rid: RID
var _display_texture: Texture2D

func _ready() -> void:
    _rd = RenderingServer.create_local_rendering_device()
    if _rd == null:
        push_error("RenderingDevice unavailable.")
        return

    var shader_source_text := FileAccess.get_file_as_string("res://shaders/compute_raymarch.glsl")
    if shader_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_raymarch.glsl")
        return

    var shader_source := RDShaderSource.new()
    shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, shader_source_text)
    var shader_spirv := _rd.shader_compile_spirv_from_source(shader_source)
    var compile_error := shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
    if compile_error != "":
        push_error("Compute shader compile error: %s" % compile_error)
        return

    _shader_rid = _rd.shader_create_from_spirv(shader_spirv)
    if !_shader_rid.is_valid():
        push_error("Failed to create compute shader.")
        return

    _pipeline_rid = _rd.compute_pipeline_create(_shader_rid)
    if !_pipeline_rid.is_valid():
        push_error("Failed to create compute pipeline.")
        return

    var fmt := RDTextureFormat.new()
    fmt.width = width
    fmt.height = height
    fmt.depth = 1
    fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
    fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

    var view := RDTextureView.new()
    _texture_rid = _rd.texture_create(fmt, view, [])
    if !_texture_rid.is_valid():
        push_error("Failed to create compute texture.")
        return

    _ubo_rid = _rd.uniform_buffer_create(16)
    if !_ubo_rid.is_valid():
        push_error("Failed to create uniform buffer.")
        return

    var img_uniform := RDUniform.new()
    img_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    img_uniform.binding = 0
    img_uniform.add_id(_texture_rid)

    var ubo_uniform := RDUniform.new()
    ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    ubo_uniform.binding = 1
    ubo_uniform.add_id(_ubo_rid)

    _uniform_set_rid = _rd.uniform_set_create([img_uniform, ubo_uniform], _shader_rid, 0)
    if !_uniform_set_rid.is_valid():
        push_error("Failed to create uniform set.")
        return

    var quad := get_node_or_null(quad_path) as MeshInstance3D
    if quad == null:
        push_error("VoxelRenderer quad_path missing or invalid.")
        return

    var mat := quad.material_override as ShaderMaterial
    if mat == null:
        mat = ShaderMaterial.new()
        mat.shader = load("res://shaders/compute_display.gdshader")
        quad.material_override = mat

    var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
    _display_texture = ImageTexture.create_from_image(image)
    mat.set_shader_parameter("compute_tex", _display_texture)

func _process(_delta: float) -> void:
    if _rd == null:
        return
    if !_pipeline_rid.is_valid() or !_uniform_set_rid.is_valid():
        return

    var params := PackedFloat32Array([Time.get_ticks_msec() / 1000.0, float(width), float(height), 0.0])
    var bytes := params.to_byte_array()
    _rd.buffer_update(_ubo_rid, 0, bytes.size(), bytes)

    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, _uniform_set_rid, 0)
    var groups_x := int(ceil(float(width) / 8.0))
    var groups_y := int(ceil(float(height) / 8.0))
    _rd.compute_list_dispatch(list, groups_x, groups_y, 1)
    _rd.compute_list_end()
    _rd.submit()
    _rd.sync()

    var data := _rd.texture_get_data(_texture_rid, 0)
    var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
    var tex := _display_texture as ImageTexture
    if tex != null:
        tex.update(image)

func _exit_tree() -> void:
    if _rd == null:
        return
    if _uniform_set_rid.is_valid():
        _rd.free_rid(_uniform_set_rid)
    if _ubo_rid.is_valid():
        _rd.free_rid(_ubo_rid)
    if _texture_rid.is_valid():
        _rd.free_rid(_texture_rid)
    if _pipeline_rid.is_valid():
        _rd.free_rid(_pipeline_rid)
    if _shader_rid.is_valid():
        _rd.free_rid(_shader_rid)
