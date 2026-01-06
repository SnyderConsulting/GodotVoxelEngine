extends Node

@export var quad_path: NodePath
@export var camera_path: NodePath
@export var width := 512
@export var height := 512
@export var chunk_size := 8
@export var chunk_grid := 3
@export var lattice_spacing := 1.0
@export var max_distance := 200.0
@export var fill_radius_ratio := 0.35
@export var fill_mode := 0
@export var noise_threshold := 0.55
@export var voxel_data_path := "res://data/voxels.json"
@export var debug_overlay := false

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _occupancy_shader_rid: RID
var _occupancy_pipeline_rid: RID
var _texture_rid: RID
var _ubo_rid: RID
var _indirection_rid: RID
var _atlas_rid: RID
var _occupancy_rid: RID
var _uniform_set_rid: RID
var _occupancy_uniform_set_rid: RID
var _occupancy_bytes := 0
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

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_F1:
        debug_overlay = !debug_overlay

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

    var occ_source_text := FileAccess.get_file_as_string("res://shaders/compute_occupancy.glsl")
    if occ_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_occupancy.glsl")
        return

    var occ_source := RDShaderSource.new()
    occ_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
    occ_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, occ_source_text)
    var occ_spirv := _rd.shader_compile_spirv_from_source(occ_source)
    var occ_error := occ_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
    if occ_error != "":
        push_error("Occupancy shader compile error: %s" % occ_error)
        return

    _occupancy_shader_rid = _rd.shader_create_from_spirv(occ_spirv)
    if !_occupancy_shader_rid.is_valid():
        push_error("Failed to create occupancy shader.")
        return

    _occupancy_pipeline_rid = _rd.compute_pipeline_create(_occupancy_shader_rid)
    if !_occupancy_pipeline_rid.is_valid():
        push_error("Failed to create occupancy pipeline.")
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

    _ubo_rid = _rd.uniform_buffer_create(160)
    if !_ubo_rid.is_valid():
        push_error("Failed to create uniform buffer.")
        return

    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var indirection_bytes := brick_count * 4
    var atlas_bytes := brick_count * chunk_size * chunk_size * chunk_size * 4
    var occupancy_bytes := brick_count * 4
    _occupancy_bytes = occupancy_bytes

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

    var occ_ubo_uniform := RDUniform.new()
    occ_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    occ_ubo_uniform.binding = 0
    occ_ubo_uniform.add_id(_ubo_rid)

    var occ_indirection_uniform := RDUniform.new()
    occ_indirection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_indirection_uniform.binding = 1
    occ_indirection_uniform.add_id(_indirection_rid)

    var occ_atlas_uniform := RDUniform.new()
    occ_atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_atlas_uniform.binding = 2
    occ_atlas_uniform.add_id(_atlas_rid)

    var occ_out_uniform := RDUniform.new()
    occ_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_out_uniform.binding = 3
    occ_out_uniform.add_id(_occupancy_rid)

    _occupancy_uniform_set_rid = _rd.uniform_set_create(
        [occ_ubo_uniform, occ_indirection_uniform, occ_atlas_uniform, occ_out_uniform],
        _occupancy_shader_rid,
        0
    )
    if !_occupancy_uniform_set_rid.is_valid():
        push_error("Failed to create occupancy uniform set.")
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
    var debug_flag := 1.0 if debug_overlay else 0.0
    var params := PackedFloat32Array([
        grid_extent, grid_extent, grid_extent, 0.0,
        -0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent, 0.0,     
        pos.x, pos.y, pos.z, 0.0,
        basis.x.x, basis.x.y, basis.x.z, 0.0,
        basis.y.x, basis.y.y, basis.y.z, 0.0,
        -basis.z.x, -basis.z.y, -basis.z.z, 0.0,
        float(width), float(height), tan_half_fov, aspect,
        voxel_size, max_distance, 0.8, 0.25,
        brick_grid, brick_grid, brick_grid, float(chunk_size),
        debug_flag, 0.0, 0.0, 0.0
    ])
    var bytes := params.to_byte_array()
    _dispatch_occupancy()
    _dispatch_compute(bytes)

func _dispatch_occupancy() -> void:
    if !_occupancy_pipeline_rid.is_valid() or !_occupancy_uniform_set_rid.is_valid():
        return
    _rd.buffer_clear(_occupancy_rid, 0, _occupancy_bytes)
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _occupancy_pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, _occupancy_uniform_set_rid, 0)
    var brick_count := chunk_grid * chunk_grid * chunk_grid
    _rd.compute_list_dispatch(list, brick_count, 1, 1)
    _rd.compute_list_end()
    _rd.submit()

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

    var atlas := PackedInt32Array()
    atlas.resize(brick_count * chunk_size * chunk_size * chunk_size)
    for i in range(atlas.size()):
        atlas[i] = 0

    var grid_extent := brick_grid * chunk_size
    var center := Vector3((grid_extent - 1) * 0.5, (grid_extent - 1) * 0.5, (grid_extent - 1) * 0.5)
    var fill_radius := float(grid_extent) * fill_radius_ratio
    var fill_radius_sq := fill_radius * fill_radius
    var points := _load_voxel_points(grid_extent)
    if points.size() > 0:
        for point in points:
            var p := point as Vector3
            var gx := int(p.x)
            var gy := int(p.y)
            var gz := int(p.z)
            if gx < 0 or gy < 0 or gz < 0 or gx >= grid_extent or gy >= grid_extent or gz >= grid_extent:
                continue
            if !((gx & 1) == (gy & 1) and (gy & 1) == (gz & 1)):
                continue
            var bx := gx / chunk_size
            var by := gy / chunk_size
            var bz := gz / chunk_size
            var lx := gx - bx * chunk_size
            var ly := gy - by * chunk_size
            var lz := gz - bz * chunk_size
            var brick_index := bx + by * brick_grid + bz * brick_grid * brick_grid
            var base_offset := brick_index * chunk_size * chunk_size * chunk_size
            var local_index := base_offset + lx + ly * chunk_size + lz * chunk_size * chunk_size
            atlas[local_index] = 1
            occupancy[brick_index] = 1
            indirection[brick_index] = brick_index + 1
    else:
        for bz in range(brick_grid):
            for by in range(brick_grid):
                for bx in range(brick_grid):
                    var brick_index := bx + by * brick_grid + bz * brick_grid * brick_grid
                    var base_offset := brick_index * chunk_size * chunk_size * chunk_size
                    var any := false
                    for lz in range(chunk_size):
                        var gz := bz * chunk_size + lz
                        for ly in range(chunk_size):
                            var gy := by * chunk_size + ly
                            for lx in range(chunk_size):
                                var gx := bx * chunk_size + lx
                                if !((gx & 1) == (gy & 1) and (gy & 1) == (gz & 1)):
                                    continue
                                var delta := Vector3(gx, gy, gz) - center
                                if delta.length_squared() > fill_radius_sq:
                                    continue
                                if fill_mode == 1:
                                    var h := int((gx * 73856093) ^ (gy * 19349663) ^ (gz * 83492791))
                                    var n := float((h & 1023)) / 1023.0
                                    if n < noise_threshold:
                                        continue
                                var local_index := base_offset + lx + ly * chunk_size + lz * chunk_size * chunk_size
                                atlas[local_index] = 1
                                any = true
                    if any:
                        occupancy[brick_index] = 1
                        indirection[brick_index] = brick_index + 1
                    else:
                        indirection[brick_index] = 0

    var ind_bytes := indirection.to_byte_array()
    _rd.buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes)
    var atlas_bytes := atlas.to_byte_array()
    _rd.buffer_update(_atlas_rid, 0, atlas_bytes.size(), atlas_bytes)
    var occ_bytes := occupancy.to_byte_array()
    _rd.buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes)

func _load_voxel_points(grid_extent: int) -> Array:
    if voxel_data_path.is_empty():
        return []
    if !FileAccess.file_exists(voxel_data_path):
        return []
    var text := FileAccess.get_file_as_string(voxel_data_path)
    if text.is_empty():
        return []
    var data: Variant = JSON.parse_string(text)
    if typeof(data) != TYPE_DICTIONARY:
        return []
    var voxels: Array = data.get("voxels", [])
    if typeof(voxels) != TYPE_ARRAY:
        return []
    var points: Array = []
    for entry in voxels:
        var arr := entry as Array
        if arr == null:
            continue
        if arr.size() < 3:
            continue
        points.append(Vector3(float(arr[0]), float(arr[1]), float(arr[2])))
    return points

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
    if _occupancy_uniform_set_rid.is_valid():
        _rd.free_rid(_occupancy_uniform_set_rid)
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
    if _occupancy_pipeline_rid.is_valid():
        _rd.free_rid(_occupancy_pipeline_rid)
    if _occupancy_shader_rid.is_valid():
        _rd.free_rid(_occupancy_shader_rid)
