extends Node

@export var quad_path: NodePath
@export var camera_path: NodePath
@export var width := 512
@export var height := 512
@export var chunk_size := 8
@export var chunk_grid := 1
@export var lattice_spacing := 1.0
@export var max_distance := 200.0

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _texture_rid: RID
var _ubo_rid: RID
var _indirection_rid: RID
var _atlas_rid: RID
var _occupancy_rid: RID
var _uniform_set_rid: RID
var _display_texture: Texture2D
var _display_material: ShaderMaterial
var _camera: Camera3D
var _render_ready := false
var _use_global_rd := false

func _ready() -> void:
    _rd = RenderingServer.get_rendering_device()
    _use_global_rd = _rd != null
    if _rd == null:
        push_error("RenderingDevice unavailable.")
        return
    if !_use_global_rd:
        push_error("Pure GPU path requires the global RenderingDevice.")
        return

    var quad := get_node_or_null(quad_path) as MeshInstance3D
    if quad == null:
        push_error("VoxelRenderer quad_path missing or invalid.")
        return
    _camera = get_node_or_null(camera_path) as Camera3D
    if _camera == null:
        push_error("VoxelRenderer camera_path missing or invalid.")
        return

    _display_material = quad.material_override as ShaderMaterial
    if _display_material == null:
        _display_material = ShaderMaterial.new()
        _display_material.shader = load("res://shaders/compute_display.gdshader")
        quad.material_override = _display_material

    _init_render_resources()

func _init_render_resources() -> void:
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
    fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT

    var view := RDTextureView.new()
    _texture_rid = _rd.texture_create(fmt, view, [])
    if !_texture_rid.is_valid():
        push_error("Failed to create compute texture.")
        return

    _ubo_rid = _rd.uniform_buffer_create(144)
    if !_ubo_rid.is_valid():
        push_error("Failed to create uniform buffer.")
        return

    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var indirection_bytes := brick_count * 4
    var atlas_bytes := brick_count * chunk_size * chunk_size * chunk_size * 4
    var occupancy_bytes := brick_count * 4

    _indirection_rid = _rd.storage_buffer_create(indirection_bytes)
    if !_indirection_rid.is_valid():
        push_error("Failed to create indirection buffer.")
        return
    _atlas_rid = _rd.storage_buffer_create(atlas_bytes)
    if !_atlas_rid.is_valid():
        push_error("Failed to create atlas buffer.")
        return
    _occupancy_rid = _rd.storage_buffer_create(occupancy_bytes)
    if !_occupancy_rid.is_valid():
        push_error("Failed to create occupancy buffer.")
        return

    _upload_brickmap_data()

    var img_uniform := RDUniform.new()
    img_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    img_uniform.binding = 0
    img_uniform.add_id(_texture_rid)

    var ubo_uniform := RDUniform.new()
    ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    ubo_uniform.binding = 1
    ubo_uniform.add_id(_ubo_rid)

    var indirection_uniform := RDUniform.new()
    indirection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    indirection_uniform.binding = 2
    indirection_uniform.add_id(_indirection_rid)

    var atlas_uniform := RDUniform.new()
    atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    atlas_uniform.binding = 3
    atlas_uniform.add_id(_atlas_rid)

    var occupancy_uniform := RDUniform.new()
    occupancy_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occupancy_uniform.binding = 4
    occupancy_uniform.add_id(_occupancy_rid)

    _uniform_set_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform, occupancy_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_rid.is_valid():
        push_error("Failed to create uniform set.")
        return

    _display_texture = _create_display_texture()
    if _display_texture == null:
        push_error("Failed to create GPU display texture.")
        return
    _display_material.set_shader_parameter("compute_tex", _display_texture)
    _render_ready = true

func _process(_delta: float) -> void:
    if _rd == null:
        return
    if !_render_ready or !_pipeline_rid.is_valid() or !_uniform_set_rid.is_valid():
        return

    var basis := _camera.global_transform.basis
    var pos := _camera.global_transform.origin
    var fov := deg_to_rad(_camera.fov)
    var aspect := float(width) / float(height)
    var tan_half_fov := tan(fov * 0.5)
    var grid_extent := float(chunk_grid * chunk_size)
    var world_extent := grid_extent * lattice_spacing
    var voxel_size := lattice_spacing
    var brick_grid := float(chunk_grid)
    var params := PackedFloat32Array([
        grid_extent, grid_extent, grid_extent, 0.0,
        -0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent, 0.0,
        pos.x, pos.y, pos.z, 0.0,
        basis.x.x, basis.x.y, basis.x.z, 0.0,
        basis.y.x, basis.y.y, basis.y.z, 0.0,
        -basis.z.x, -basis.z.y, -basis.z.z, 0.0,
        float(width), float(height), tan_half_fov, aspect,
        voxel_size, max_distance, 0.0, 0.0,
        brick_grid, brick_grid, brick_grid, float(chunk_size)
    ])
    var bytes := params.to_byte_array()
    _dispatch_compute(bytes)

func _dispatch_compute(bytes: PackedByteArray) -> void:
    if !_render_ready or !_pipeline_rid.is_valid() or !_uniform_set_rid.is_valid():
        return
    _rd.buffer_update(_ubo_rid, 0, bytes.size(), bytes)

    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, _uniform_set_rid, 0)
    var groups_x := int(ceil(float(width) / 8.0))
    var groups_y := int(ceil(float(height) / 8.0))
    _rd.compute_list_dispatch(list, groups_x, groups_y, 1)
    _rd.compute_list_end()
    _rd.submit()

func _upload_brickmap_data() -> void:
    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var indirection := PackedInt32Array()
    var occupancy := PackedInt32Array()
    indirection.resize(brick_count)
    occupancy.resize(brick_count)
    for i in range(brick_count):
        indirection[i] = 0
        occupancy[i] = 0

    var center_brick := int(brick_grid / 2)
    var brick_index := center_brick + center_brick * brick_grid + center_brick * brick_grid * brick_grid
    indirection[brick_index] = brick_index + 1
    occupancy[brick_index] = 1

    var atlas := PackedInt32Array()
    atlas.resize(brick_count * chunk_size * chunk_size * chunk_size)
    for i in range(atlas.size()):
        atlas[i] = 0

    var base_offset := brick_index * chunk_size * chunk_size * chunk_size
    var min_cell: int = int(max(0, int(chunk_size / 2) - 2))
    var max_cell: int = int(min(chunk_size - 1, int(chunk_size / 2) + 2))
    for z in range(min_cell, max_cell + 1):
        for y in range(min_cell, max_cell + 1):
            for x in range(min_cell, max_cell + 1):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var local_index: int = base_offset + x + y * chunk_size + z * chunk_size * chunk_size
                atlas[local_index] = 1

    var ind_bytes := indirection.to_byte_array()
    _rd.buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes)
    var atlas_bytes := atlas.to_byte_array()
    _rd.buffer_update(_atlas_rid, 0, atlas_bytes.size(), atlas_bytes)
    var occ_bytes := occupancy.to_byte_array()
    _rd.buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes)

func _create_display_texture() -> Texture2D:
    if _use_global_rd and ClassDB.class_exists("Texture2DRD"):
        var rd_tex := ClassDB.instantiate("Texture2DRD") as Object
        if rd_tex != null:
            var props: Array = rd_tex.get_property_list()
            for prop in props:
                var prop_info := prop as Dictionary
                if prop_info.get("name", "") == "texture_rd_rid":
                    rd_tex.set("texture_rd_rid", _texture_rid)
                    return rd_tex as Texture2D
    return null

func _exit_tree() -> void:
    if _rd == null:
        return
    if _uniform_set_rid.is_valid():
        _rd.free_rid(_uniform_set_rid)
    if _ubo_rid.is_valid():
        _rd.free_rid(_ubo_rid)
    if _texture_rid.is_valid():
        _rd.free_rid(_texture_rid)
    if _indirection_rid.is_valid():
        _rd.free_rid(_indirection_rid)
    if _atlas_rid.is_valid():
        _rd.free_rid(_atlas_rid)
    if _occupancy_rid.is_valid():
        _rd.free_rid(_occupancy_rid)
    if _pipeline_rid.is_valid():
        _rd.free_rid(_pipeline_rid)
    if _shader_rid.is_valid():
        _rd.free_rid(_shader_rid)
