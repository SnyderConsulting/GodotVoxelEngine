extends Node

@export var quad_path: NodePath
@export var camera_path: NodePath
@export var width: int = 512
@export var height: int = 512
@export var chunk_size: int = 8
@export var chunk_grid: int = 3
@export var lattice_spacing: float = 1.0
@export var max_distance: float = 200.0
@export var auto_max_distance: bool = true
@export var fill_radius_ratio: float = 0.35
@export var fill_mode: int = 0
@export var noise_threshold: float = 0.55
@export var voxel_data_path: String = "res://data/voxels.json"
@export var material_data_path: String = "res://data/materials.json"
@export var gravity_dir: Vector3 = Vector3(0, -1, 0)
@export var world_rotation: Vector3 = Vector3.ZERO
@export var light_enabled: bool = true
@export var light_every: int = 1
@export var metrics_every: int = 30
@export var debug_logging: bool = false
@export var debug_log_every: int = 60
@export var debug_render_thread_ping: bool = false
@export var debug_probe_enabled: bool = false
@export var debug_probe_cell: Vector3i = Vector3i(0, 0, 0)
@export var debug_probe_every: int = 60
@export var sim_enabled: bool = false
@export var sim_every: int = 1
@export var sim_clear_output: bool = true
@export var diag_enabled: bool = false
@export var diag_every: int = 60
@export var diag_log_buffers: bool = false
@export var diag_log_dispatch: bool = false

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _occupancy_shader_rid: RID
var _occupancy_pipeline_rid: RID
var _sim_shader_rid: RID
var _sim_pipeline_rid: RID
var _light_shader_rid: RID
var _light_pipeline_rid: RID
var _active_list_shader_rid: RID
var _active_list_pipeline_rid: RID
var _active_dispatch_shader_rid: RID
var _active_dispatch_pipeline_rid: RID
var _texture_rid: RID
var _ubo_rid: RID
var _indirection_rid: RID
var _atlas_a_rid: RID
var _atlas_b_rid: RID
var _seed_a_rid: RID
var _seed_b_rid: RID
var _preview_rid: RID
var _cursor_rid: RID
var _preview_occ_rid: RID
var _light_a_rid: RID
var _light_b_rid: RID
var _occupancy_rid: RID
var _metrics_rid: RID
var _active_list_rid: RID
var _active_count_rid: RID
var _sim_dispatch_rid: RID
var _material_props_rid: RID
var _preview_cells: Array = []
var _cursor_cell := Vector3i(-1, -1, -1)
var _preview_occ_bricks: PackedInt32Array = PackedInt32Array()
var _uniform_set_a_light_a_rid: RID
var _uniform_set_a_light_b_rid: RID
var _uniform_set_b_light_a_rid: RID
var _uniform_set_b_light_b_rid: RID
var _occupancy_uniform_set_a_rid: RID
var _occupancy_uniform_set_b_rid: RID
var _sim_uniform_set_ab: RID
var _sim_uniform_set_ba: RID
var _active_list_uniform_set_rid: RID
var _active_dispatch_uniform_set_rid: RID
var _light_uniform_set_a_ab: RID
var _light_uniform_set_a_ba: RID
var _light_uniform_set_b_ab: RID
var _light_uniform_set_b_ba: RID
var _occupancy_bytes := 0
var _metrics_bytes := 0
var _atlas_bytes := 0
var _active_list_bytes := 0
var _active_count_bytes := 0
var _sim_dispatch_bytes := 0
var _material_props_bytes := 0
var _display_texture: Texture2D
var _display_material: ShaderMaterial
var _camera: Camera3D
var _render_ready := false
var _use_global_rd := false
var _metrics_frame := 0
var _debug_frame := 0
var _debug_probe_frame := 0
var _sim_frame := 0
var _atlas_use_a := true
var _light_use_a := true
var _light_frame := 0
var _active_list_ready := false
var _indirection_cpu: PackedInt32Array = PackedInt32Array()
var _rng := RandomNumberGenerator.new()

func _diag(msg: String) -> void:
    if !diag_enabled:
        return
    print("VoxelRenderer diag | frame=%d %s" % [_debug_frame, msg])

func _ready() -> void:
    _diag("ready start width=%d height=%d chunk_size=%d chunk_grid=%d lattice=%.3f" % [
        width, height, chunk_size, chunk_grid, lattice_spacing
    ])
    _rng.seed = Time.get_ticks_usec()
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
    _diag("ready end render_ready=%s" % str(_render_ready))

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

    var sim_source_text := FileAccess.get_file_as_string("res://shaders/compute_sim.glsl")
    if sim_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_sim.glsl")
    else:
        var sim_source := RDShaderSource.new()
        sim_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        sim_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, sim_source_text)
        var sim_spirv := _rd.shader_compile_spirv_from_source(sim_source)
        var sim_error := sim_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if sim_error != "":
            push_error("Sim shader compile error: %s" % sim_error)
        else:
            _sim_shader_rid = _rd.shader_create_from_spirv(sim_spirv)
            if !_sim_shader_rid.is_valid():
                push_error("Failed to create sim shader.")
            else:
                _sim_pipeline_rid = _rd.compute_pipeline_create(_sim_shader_rid)
                if !_sim_pipeline_rid.is_valid():
                    push_error("Failed to create sim pipeline.")

    var light_source_text := FileAccess.get_file_as_string("res://shaders/compute_light.glsl")
    if light_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_light.glsl")
    else:
        var light_source := RDShaderSource.new()
        light_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        light_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, light_source_text)
        var light_spirv := _rd.shader_compile_spirv_from_source(light_source)
        var light_error := light_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if light_error != "":
            push_error("Light shader compile error: %s" % light_error)
        else:
            _light_shader_rid = _rd.shader_create_from_spirv(light_spirv)
            if !_light_shader_rid.is_valid():
                push_error("Failed to create light shader.")
            else:
                _light_pipeline_rid = _rd.compute_pipeline_create(_light_shader_rid)
                if !_light_pipeline_rid.is_valid():
                    push_error("Failed to create light pipeline.")

    var active_list_source_text := FileAccess.get_file_as_string("res://shaders/compute_active_list.glsl")
    if active_list_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_active_list.glsl")
    else:
        var active_list_source := RDShaderSource.new()
        active_list_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        active_list_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, active_list_source_text)
        var active_list_spirv := _rd.shader_compile_spirv_from_source(active_list_source)
        var active_list_error := active_list_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if active_list_error != "":
            push_error("Active list shader compile error: %s" % active_list_error)
        else:
            _active_list_shader_rid = _rd.shader_create_from_spirv(active_list_spirv)
            if !_active_list_shader_rid.is_valid():
                push_error("Failed to create active list shader.")
            else:
                _active_list_pipeline_rid = _rd.compute_pipeline_create(_active_list_shader_rid)
                if !_active_list_pipeline_rid.is_valid():
                    push_error("Failed to create active list pipeline.")

    var active_dispatch_source_text := FileAccess.get_file_as_string("res://shaders/compute_active_dispatch.glsl")
    if active_dispatch_source_text.is_empty():
        push_error("Missing compute shader source: res://shaders/compute_active_dispatch.glsl")
    else:
        var active_dispatch_source := RDShaderSource.new()
        active_dispatch_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        active_dispatch_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, active_dispatch_source_text)
        var active_dispatch_spirv := _rd.shader_compile_spirv_from_source(active_dispatch_source)
        var active_dispatch_error := active_dispatch_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if active_dispatch_error != "":
            push_error("Active dispatch shader compile error: %s" % active_dispatch_error)
        else:
            _active_dispatch_shader_rid = _rd.shader_create_from_spirv(active_dispatch_spirv)
            if !_active_dispatch_shader_rid.is_valid():
                push_error("Failed to create active dispatch shader.")
            else:
                _active_dispatch_pipeline_rid = _rd.compute_pipeline_create(_active_dispatch_shader_rid)
                if !_active_dispatch_pipeline_rid.is_valid():
                    push_error("Failed to create active dispatch pipeline.")

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

    _ubo_rid = _rd.uniform_buffer_create(208)
    if !_ubo_rid.is_valid():
        push_error("Failed to create uniform buffer.")
        return

    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var indirection_bytes := brick_count * 4
    _atlas_bytes = brick_count * chunk_size * chunk_size * chunk_size * 4
    var occupancy_bytes := brick_count * 4
    _occupancy_bytes = occupancy_bytes
    _metrics_bytes = 16

    _indirection_rid = _rd.storage_buffer_create(indirection_bytes)
    if !_indirection_rid.is_valid():
        push_error("Failed to create indirection buffer.")
        return
    _atlas_a_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_atlas_a_rid.is_valid():
        push_error("Failed to create atlas buffer A.")
        return
    _atlas_b_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_atlas_b_rid.is_valid():
        push_error("Failed to create atlas buffer B.")
        return
    _seed_a_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_seed_a_rid.is_valid():
        push_error("Failed to create seed buffer A.")
        return
    _seed_b_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_seed_b_rid.is_valid():
        push_error("Failed to create seed buffer B.")
        return
    _preview_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_preview_rid.is_valid():
        push_error("Failed to create preview buffer.")
        return
    _cursor_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_cursor_rid.is_valid():
        push_error("Failed to create cursor buffer.")
        return
    var preview_occ_bytes := brick_count * 4
    _preview_occ_rid = _rd.storage_buffer_create(preview_occ_bytes)
    if !_preview_occ_rid.is_valid():
        push_error("Failed to create preview occupancy buffer.")
        return
    _light_a_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_light_a_rid.is_valid():
        push_error("Failed to create light buffer A.")
        return
    _light_b_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_light_b_rid.is_valid():
        push_error("Failed to create light buffer B.")
        return
    _occupancy_rid = _rd.storage_buffer_create(occupancy_bytes)
    if !_occupancy_rid.is_valid():
        push_error("Failed to create occupancy buffer.")
        return
    _metrics_rid = _rd.storage_buffer_create(_metrics_bytes)
    if !_metrics_rid.is_valid():
        push_error("Failed to create metrics buffer.")
        return

    _active_list_bytes = brick_count * 4
    _active_count_bytes = 4
    _sim_dispatch_bytes = 16
    _active_list_rid = _rd.storage_buffer_create(_active_list_bytes)
    if !_active_list_rid.is_valid():
        push_error("Failed to create active list buffer.")
        return
    _active_count_rid = _rd.storage_buffer_create(_active_count_bytes)
    if !_active_count_rid.is_valid():
        push_error("Failed to create active count buffer.")
        return
    var dispatch_init := PackedInt32Array([0, 1, 1, 0]).to_byte_array()
    _sim_dispatch_rid = _rd.storage_buffer_create(
        _sim_dispatch_bytes,
        dispatch_init,
        RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
    )
    if !_sim_dispatch_rid.is_valid():
        push_error("Failed to create sim dispatch buffer.")
        return
    _material_props_bytes = 0
    var material_bytes := _load_material_props()
    if material_bytes.size() == 0:
        push_error("Failed to load material properties.")
        return
    _material_props_bytes = material_bytes.size()
    _material_props_rid = _rd.storage_buffer_create(_material_props_bytes, material_bytes)
    if !_material_props_rid.is_valid():
        push_error("Failed to create material properties buffer.")
        return

    if diag_enabled and diag_log_buffers:
        _diag("buffers allocated atlas_bytes=%d indirection_bytes=%d occupancy_bytes=%d metrics_bytes=%d active_list_bytes=%d" % [
            _atlas_bytes, indirection_bytes, occupancy_bytes, _metrics_bytes, _active_list_bytes
        ])
    _upload_brickmap_data()
    if _light_a_rid.is_valid():
        _rd.buffer_clear(_light_a_rid, 0, _atlas_bytes)
    if _light_b_rid.is_valid():
        _rd.buffer_clear(_light_b_rid, 0, _atlas_bytes)
    if _seed_a_rid.is_valid():
        _rd.buffer_clear(_seed_a_rid, 0, _atlas_bytes)
    if _seed_b_rid.is_valid():
        _rd.buffer_clear(_seed_b_rid, 0, _atlas_bytes)
    if _preview_rid.is_valid():
        _rd.buffer_clear(_preview_rid, 0, _atlas_bytes)
    if _cursor_rid.is_valid():
        _rd.buffer_clear(_cursor_rid, 0, _atlas_bytes)
    if _preview_occ_rid.is_valid():
        _rd.buffer_clear(_preview_occ_rid, 0, brick_count * 4)

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

    var atlas_uniform_a := RDUniform.new()
    atlas_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    atlas_uniform_a.binding = 3
    atlas_uniform_a.add_id(_atlas_a_rid)

    var atlas_uniform_b := RDUniform.new()
    atlas_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    atlas_uniform_b.binding = 3
    atlas_uniform_b.add_id(_atlas_b_rid)

    var occupancy_uniform := RDUniform.new()
    occupancy_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occupancy_uniform.binding = 4
    occupancy_uniform.add_id(_occupancy_rid)
    var metrics_uniform := RDUniform.new()
    metrics_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    metrics_uniform.binding = 5
    metrics_uniform.add_id(_metrics_rid)
    var preview_uniform := RDUniform.new()
    preview_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    preview_uniform.binding = 7
    preview_uniform.add_id(_preview_rid)
    var cursor_uniform := RDUniform.new()
    cursor_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    cursor_uniform.binding = 8
    cursor_uniform.add_id(_cursor_rid)
    var preview_occ_uniform := RDUniform.new()
    preview_occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    preview_occ_uniform.binding = 9
    preview_occ_uniform.add_id(_preview_occ_rid)

    var light_uniform_a := RDUniform.new()
    light_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    light_uniform_a.binding = 6
    light_uniform_a.add_id(_light_a_rid)

    var light_uniform_b := RDUniform.new()
    light_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    light_uniform_b.binding = 6
    light_uniform_b.add_id(_light_b_rid)

    _uniform_set_a_light_a_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_a, occupancy_uniform, metrics_uniform, light_uniform_a, preview_uniform, cursor_uniform, preview_occ_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_a_light_a_rid.is_valid():
        push_error("Failed to create uniform set A (light A).")
        return
    _uniform_set_a_light_b_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_a, occupancy_uniform, metrics_uniform, light_uniform_b, preview_uniform, cursor_uniform, preview_occ_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_a_light_b_rid.is_valid():
        push_error("Failed to create uniform set A (light B).")
        return
    _uniform_set_b_light_a_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_b, occupancy_uniform, metrics_uniform, light_uniform_a, preview_uniform, cursor_uniform, preview_occ_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_b_light_a_rid.is_valid():
        push_error("Failed to create uniform set B (light A).")
        return
    _uniform_set_b_light_b_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_b, occupancy_uniform, metrics_uniform, light_uniform_b, preview_uniform, cursor_uniform, preview_occ_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_b_light_b_rid.is_valid():
        push_error("Failed to create uniform set B (light B).")
        return

    var occ_ubo_uniform := RDUniform.new()
    occ_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    occ_ubo_uniform.binding = 0
    occ_ubo_uniform.add_id(_ubo_rid)

    var occ_indirection_uniform := RDUniform.new()
    occ_indirection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_indirection_uniform.binding = 1
    occ_indirection_uniform.add_id(_indirection_rid)

    var occ_atlas_uniform_a := RDUniform.new()
    occ_atlas_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_atlas_uniform_a.binding = 2
    occ_atlas_uniform_a.add_id(_atlas_a_rid)

    var occ_atlas_uniform_b := RDUniform.new()
    occ_atlas_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_atlas_uniform_b.binding = 2
    occ_atlas_uniform_b.add_id(_atlas_b_rid)

    var occ_out_uniform := RDUniform.new()
    occ_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_out_uniform.binding = 3
    occ_out_uniform.add_id(_occupancy_rid)
    var occ_metrics_uniform := RDUniform.new()
    occ_metrics_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    occ_metrics_uniform.binding = 4
    occ_metrics_uniform.add_id(_metrics_rid)

    _occupancy_uniform_set_a_rid = _rd.uniform_set_create(
        [occ_ubo_uniform, occ_indirection_uniform, occ_atlas_uniform_a, occ_out_uniform, occ_metrics_uniform],
        _occupancy_shader_rid,
        0
    )
    if !_occupancy_uniform_set_a_rid.is_valid():
        push_error("Failed to create occupancy uniform set A.")
        return
    _occupancy_uniform_set_b_rid = _rd.uniform_set_create(
        [occ_ubo_uniform, occ_indirection_uniform, occ_atlas_uniform_b, occ_out_uniform, occ_metrics_uniform],
        _occupancy_shader_rid,
        0
    )
    if !_occupancy_uniform_set_b_rid.is_valid():
        push_error("Failed to create occupancy uniform set B.")
        return

    if _active_list_shader_rid.is_valid():
        var active_ubo_uniform := RDUniform.new()
        active_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        active_ubo_uniform.binding = 0
        active_ubo_uniform.add_id(_ubo_rid)

        var active_occ_uniform := RDUniform.new()
        active_occ_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        active_occ_uniform.binding = 1
        active_occ_uniform.add_id(_occupancy_rid)

        var active_list_uniform := RDUniform.new()
        active_list_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        active_list_uniform.binding = 2
        active_list_uniform.add_id(_active_list_rid)

        var active_count_uniform := RDUniform.new()
        active_count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        active_count_uniform.binding = 3
        active_count_uniform.add_id(_active_count_rid)

        _active_list_uniform_set_rid = _rd.uniform_set_create(
            [active_ubo_uniform, active_occ_uniform, active_list_uniform, active_count_uniform],
            _active_list_shader_rid,
            0
        )
        if !_active_list_uniform_set_rid.is_valid():
            push_error("Failed to create active list uniform set.")
            return

    if _active_dispatch_shader_rid.is_valid():
        var active_dispatch_ubo_uniform := RDUniform.new()
        active_dispatch_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        active_dispatch_ubo_uniform.binding = 0
        active_dispatch_ubo_uniform.add_id(_ubo_rid)

        var active_dispatch_count_uniform := RDUniform.new()
        active_dispatch_count_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        active_dispatch_count_uniform.binding = 1
        active_dispatch_count_uniform.add_id(_active_count_rid)

        var active_dispatch_args_uniform := RDUniform.new()
        active_dispatch_args_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        active_dispatch_args_uniform.binding = 2
        active_dispatch_args_uniform.add_id(_sim_dispatch_rid)

        _active_dispatch_uniform_set_rid = _rd.uniform_set_create(
            [active_dispatch_ubo_uniform, active_dispatch_count_uniform, active_dispatch_args_uniform],
            _active_dispatch_shader_rid,
            0
        )
        if !_active_dispatch_uniform_set_rid.is_valid():
            push_error("Failed to create active dispatch uniform set.")
            return

    if _light_shader_rid.is_valid():
        var light_ubo_uniform := RDUniform.new()
        light_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        light_ubo_uniform.binding = 0
        light_ubo_uniform.add_id(_ubo_rid)

        var light_indirection_uniform := RDUniform.new()
        light_indirection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_indirection_uniform.binding = 1
        light_indirection_uniform.add_id(_indirection_rid)

        var light_atlas_uniform_a := RDUniform.new()
        light_atlas_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_atlas_uniform_a.binding = 2
        light_atlas_uniform_a.add_id(_atlas_a_rid)

        var light_atlas_uniform_b := RDUniform.new()
        light_atlas_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_atlas_uniform_b.binding = 2
        light_atlas_uniform_b.add_id(_atlas_b_rid)

        var light_in_uniform_a := RDUniform.new()
        light_in_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_in_uniform_a.binding = 3
        light_in_uniform_a.add_id(_light_a_rid)

        var light_in_uniform_b := RDUniform.new()
        light_in_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_in_uniform_b.binding = 3
        light_in_uniform_b.add_id(_light_b_rid)

        var light_out_uniform_a := RDUniform.new()
        light_out_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_out_uniform_a.binding = 4
        light_out_uniform_a.add_id(_light_a_rid)

        var light_out_uniform_b := RDUniform.new()
        light_out_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        light_out_uniform_b.binding = 4
        light_out_uniform_b.add_id(_light_b_rid)

        _light_uniform_set_a_ab = _rd.uniform_set_create(
            [light_ubo_uniform, light_indirection_uniform, light_atlas_uniform_a, light_in_uniform_a, light_out_uniform_b],
            _light_shader_rid,
            0
        )
        if !_light_uniform_set_a_ab.is_valid():
            push_error("Failed to create light uniform set A AB.")
            return
        _light_uniform_set_a_ba = _rd.uniform_set_create(
            [light_ubo_uniform, light_indirection_uniform, light_atlas_uniform_a, light_in_uniform_b, light_out_uniform_a],
            _light_shader_rid,
            0
        )
        if !_light_uniform_set_a_ba.is_valid():
            push_error("Failed to create light uniform set A BA.")
            return
        _light_uniform_set_b_ab = _rd.uniform_set_create(
            [light_ubo_uniform, light_indirection_uniform, light_atlas_uniform_b, light_in_uniform_a, light_out_uniform_b],
            _light_shader_rid,
            0
        )
        if !_light_uniform_set_b_ab.is_valid():
            push_error("Failed to create light uniform set B AB.")
            return
        _light_uniform_set_b_ba = _rd.uniform_set_create(
            [light_ubo_uniform, light_indirection_uniform, light_atlas_uniform_b, light_in_uniform_b, light_out_uniform_a],
            _light_shader_rid,
            0
        )
        if !_light_uniform_set_b_ba.is_valid():
            push_error("Failed to create light uniform set B BA.")
            return

    if _sim_shader_rid.is_valid():
        var sim_ubo_uniform := RDUniform.new()
        sim_ubo_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        sim_ubo_uniform.binding = 0
        sim_ubo_uniform.add_id(_ubo_rid)

        var sim_indirection_uniform := RDUniform.new()
        sim_indirection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_indirection_uniform.binding = 1
        sim_indirection_uniform.add_id(_indirection_rid)

        var sim_in_a := RDUniform.new()
        sim_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER     
        sim_in_a.binding = 2
        sim_in_a.add_id(_atlas_a_rid)

        var sim_out_b := RDUniform.new()
        sim_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER    
        sim_out_b.binding = 3
        sim_out_b.add_id(_atlas_b_rid)

        var sim_active_list_uniform := RDUniform.new()
        sim_active_list_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_active_list_uniform.binding = 4
        sim_active_list_uniform.add_id(_active_list_rid)
        var sim_seed_in_a := RDUniform.new()
        sim_seed_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_seed_in_a.binding = 5
        sim_seed_in_a.add_id(_seed_a_rid)
        var sim_seed_out_b := RDUniform.new()
        sim_seed_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_seed_out_b.binding = 6
        sim_seed_out_b.add_id(_seed_b_rid)
        var sim_material_uniform := RDUniform.new()
        sim_material_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_material_uniform.binding = 7
        sim_material_uniform.add_id(_material_props_rid)

        _sim_uniform_set_ab = _rd.uniform_set_create(
            [
                sim_ubo_uniform,
                sim_indirection_uniform,
                sim_in_a,
                sim_out_b,
                sim_active_list_uniform,
                sim_seed_in_a,
                sim_seed_out_b,
                sim_material_uniform
            ],
            _sim_shader_rid,
            0
        )
        if !_sim_uniform_set_ab.is_valid():
            push_error("Failed to create sim uniform set AB.")
        var sim_in_b := RDUniform.new()
        sim_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_in_b.binding = 2
        sim_in_b.add_id(_atlas_b_rid)

        var sim_out_a := RDUniform.new()
        sim_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER    
        sim_out_a.binding = 3
        sim_out_a.add_id(_atlas_a_rid)
        var sim_seed_in_b := RDUniform.new()
        sim_seed_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_seed_in_b.binding = 5
        sim_seed_in_b.add_id(_seed_b_rid)
        var sim_seed_out_a := RDUniform.new()
        sim_seed_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_seed_out_a.binding = 6
        sim_seed_out_a.add_id(_seed_a_rid)
        var sim_material_uniform_ba := RDUniform.new()
        sim_material_uniform_ba.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        sim_material_uniform_ba.binding = 7
        sim_material_uniform_ba.add_id(_material_props_rid)

        _sim_uniform_set_ba = _rd.uniform_set_create(
            [
                sim_ubo_uniform,
                sim_indirection_uniform,
                sim_in_b,
                sim_out_a,
                sim_active_list_uniform,
                sim_seed_in_b,
                sim_seed_out_a,
                sim_material_uniform_ba
            ],
            _sim_shader_rid,
            0
        )
        if !_sim_uniform_set_ba.is_valid():
            push_error("Failed to create sim uniform set BA.")

    _display_texture = _create_display_texture()
    if _display_texture == null:
        push_error("Failed to create GPU display texture.")
        return
    _display_material.set_shader_parameter("compute_tex", _display_texture)
    _render_ready = true

func is_render_ready() -> bool:
    return _render_ready

func _process(_delta: float) -> void:
    if _rd == null:
        return
    if !_render_ready or !_pipeline_rid.is_valid():
        return

    _debug_frame += 1
    var basis := _camera.global_transform.basis
    var pos := _camera.global_transform.origin
    var fov := deg_to_rad(_camera.fov)
    var aspect := float(width) / float(height)
    var tan_half_fov := tan(fov * 0.5)
    var grid_extent := float(chunk_grid * chunk_size)
    var world_extent := grid_extent * lattice_spacing
    var voxel_size := lattice_spacing
    var brick_grid := float(chunk_grid)
    var grid_extent_i := chunk_grid * chunk_size
    var world_basis := Basis.from_euler(world_rotation)
    var inv_world_basis := world_basis.inverse()
    var gravity_world := _normalized_gravity()
    var gravity := inv_world_basis * gravity_world
    var origin := Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var effective_max_distance := max_distance
    if auto_max_distance:
        var world_center := origin + Vector3.ONE * (0.5 * world_extent)
        var dist_to_center := pos.distance_to(world_center)
        var diag_half := sqrt(3.0) * (world_extent * 0.5)
        var required_max := dist_to_center + diag_half + voxel_size * 4.0
        if required_max > effective_max_distance:
            effective_max_distance = required_max
    var params := PackedFloat32Array([
        grid_extent, grid_extent, grid_extent, 0.0,
        origin.x, origin.y, origin.z, 0.0,
        pos.x, pos.y, pos.z, 0.0,
        basis.x.x, basis.x.y, basis.x.z, 0.0,
        basis.y.x, basis.y.y, basis.y.z, 0.0,
        -basis.z.x, -basis.z.y, -basis.z.z, 0.0,
        float(width), float(height), tan_half_fov, aspect,
        voxel_size, effective_max_distance, 0.8, 0.25,
        brick_grid, brick_grid, brick_grid, float(chunk_size),
        gravity.x, gravity.y, gravity.z, 0.0,
        world_basis.x.x, world_basis.x.y, world_basis.x.z, 0.0,
        world_basis.y.x, world_basis.y.y, world_basis.y.z, 0.0,
        world_basis.z.x, world_basis.z.y, world_basis.z.z, 0.0
    ])
    var bytes := params.to_byte_array()
    _update_params(bytes)
    _debug_log_snapshot(pos, basis, world_extent)
    _reset_metrics()
    _dispatch_occupancy()
    _dispatch_active_list()
    _dispatch_active_dispatch()
    _dispatch_sim(grid_extent_i)
    _dispatch_light(grid_extent_i)
    _dispatch_compute()
    _readback_metrics()
    _debug_request_probe()

func _update_params(bytes: PackedByteArray) -> void:
    if _rd == null or !_ubo_rid.is_valid():
        return
    _rd.buffer_update(_ubo_rid, 0, bytes.size(), bytes)

func _normalized_gravity() -> Vector3:
    if gravity_dir.length() < 0.001:
        return Vector3(0, -1, 0)
    return gravity_dir.normalized()

func _prime_active_list() -> void:
    if _active_list_ready:
        return
    _dispatch_active_list()
    _dispatch_active_dispatch()

func _dispatch_sim(_grid_extent: int) -> void:
    if !sim_enabled:
        return
    if !_sim_pipeline_rid.is_valid():
        return
    _sim_frame += 1
    var every: int = sim_every
    if every < 1:
        every = 1
    if _sim_frame % every != 0:
        return
    var use_a := _atlas_use_a
    var uniform_set := _sim_uniform_set_ab if use_a else _sim_uniform_set_ba    
    if !uniform_set.is_valid():
        return
    if !_sim_dispatch_rid.is_valid():
        return
    if !_active_list_ready:
        return
    if diag_enabled and (_debug_frame % max(1, diag_every) == 0):
        print("Sim dispatch | frame=%d atlas_in=%s" % [_debug_frame, "A" if use_a else "B"])
    var atlas_out := _atlas_b_rid if use_a else _atlas_a_rid
    var seed_out := _seed_b_rid if use_a else _seed_a_rid
    if sim_clear_output and _atlas_bytes > 0:
        _rd.buffer_clear(atlas_out, 0, _atlas_bytes)
        if seed_out.is_valid():
            _rd.buffer_clear(seed_out, 0, _atlas_bytes)
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _sim_pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, uniform_set, 0)
    _rd.compute_list_dispatch_indirect(list, _sim_dispatch_rid, 0)
    _rd.compute_list_end()
    _atlas_use_a = !use_a

func _reset_metrics() -> void:
    if !_metrics_rid.is_valid():
        return
    _rd.buffer_clear(_metrics_rid, 0, _metrics_bytes)

func _dispatch_occupancy() -> void:
    if !_occupancy_pipeline_rid.is_valid():
        return
    var uniform_set := _occupancy_uniform_set_a_rid if _atlas_use_a else _occupancy_uniform_set_b_rid
    if !uniform_set.is_valid():
        return
    _rd.buffer_clear(_occupancy_rid, 0, _occupancy_bytes)
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _occupancy_pipeline_rid)       
    _rd.compute_list_bind_uniform_set(list, uniform_set, 0)
    var brick_count := chunk_grid * chunk_grid * chunk_grid
    _rd.compute_list_dispatch(list, brick_count, 1, 1)
    _rd.compute_list_end()

func _dispatch_active_list() -> void:
    if !_active_list_pipeline_rid.is_valid():
        return
    if !_active_list_uniform_set_rid.is_valid():
        return
    _active_list_ready = false
    if _active_count_bytes > 0:
        _rd.buffer_clear(_active_count_rid, 0, _active_count_bytes)
    var brick_count := chunk_grid * chunk_grid * chunk_grid
    if brick_count <= 0:
        return
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _active_list_pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, _active_list_uniform_set_rid, 0)
    _rd.compute_list_dispatch(list, brick_count, 1, 1)
    _rd.compute_list_end()

func _dispatch_active_dispatch() -> void:
    if !_active_dispatch_pipeline_rid.is_valid():
        return
    if !_active_dispatch_uniform_set_rid.is_valid():
        return
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _active_dispatch_pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, _active_dispatch_uniform_set_rid, 0)
    _rd.compute_list_dispatch(list, 1, 1, 1)
    _rd.compute_list_end()
    _active_list_ready = true

func _dispatch_light(grid_extent: int) -> void:
    if !light_enabled:
        return
    if !_light_pipeline_rid.is_valid():
        return
    _light_frame += 1
    var every: int = light_every
    if every < 1:
        every = 1
    if _light_frame % every != 0:
        return
    var uniform_set := _current_light_uniform_set()
    if !uniform_set.is_valid():
        return
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _light_pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, uniform_set, 0)
    var groups := int(ceil(float(grid_extent) / 4.0))
    _rd.compute_list_dispatch(list, groups, groups, groups)
    _rd.compute_list_end()
    _light_use_a = !_light_use_a

func _current_raymarch_uniform_set() -> RID:
    if _atlas_use_a:
        return _uniform_set_a_light_a_rid if _light_use_a else _uniform_set_a_light_b_rid
    return _uniform_set_b_light_a_rid if _light_use_a else _uniform_set_b_light_b_rid

func _current_light_uniform_set() -> RID:
    if _atlas_use_a:
        return _light_uniform_set_a_ab if _light_use_a else _light_uniform_set_a_ba
    return _light_uniform_set_b_ab if _light_use_a else _light_uniform_set_b_ba

func _readback_metrics() -> void:
    _metrics_frame += 1
    var every: int = metrics_every
    if every < 1:
        every = 1
    if _metrics_frame % every != 0:
        return
    if !_metrics_rid.is_valid():
        return
    RenderingServer.call_on_render_thread(Callable(self, "_readback_metrics_on_render_thread"))

func _readback_metrics_on_render_thread() -> void:
    if _rd == null or !_metrics_rid.is_valid():
        return
    var bytes := _rd.buffer_get_data(_metrics_rid)
    var ints := bytes.to_int32_array()
    if ints.size() < 4:
        return
    var ray_count := ints[0]
    var hit_count := ints[1]
    var step_count := ints[2]
    var occupied_bricks := ints[3]
    var active_bricks := -1
    if _active_count_rid.is_valid():
        var active_bytes := _rd.buffer_get_data(_active_count_rid, 0, 4)
        if active_bytes.size() >= 4:
            var active_vals := active_bytes.to_int32_array()
            if active_vals.size() > 0:
                active_bricks = active_vals[0]
    var avg_steps := 0.0
    if ray_count > 0:
        avg_steps = float(step_count) / float(ray_count)
    var main_thread := true
    var total_bricks := chunk_grid * chunk_grid * chunk_grid
    var groups_per_brick := int(ceil(float(chunk_size) / 4.0))
    var indirect_groups := -1
    var full_groups := int(ceil(float(chunk_grid * chunk_size) / 4.0))
    if active_bricks >= 0:
        indirect_groups = active_bricks * groups_per_brick * groups_per_brick * groups_per_brick
    var full_group_count := full_groups * full_groups * full_groups
    print("GPU metrics | rays=%d hits=%d avg_steps=%.2f occupied_bricks=%d active_bricks=%d total_bricks=%d indirect_groups=%d full_groups=%d main_thread=%s" % [
        ray_count,
        hit_count,
        avg_steps,
        occupied_bricks,
        active_bricks,
        total_bricks,
        indirect_groups,
        full_group_count,
        str(main_thread)
    ])

func _dispatch_compute() -> void:
    if !_render_ready or !_pipeline_rid.is_valid():
        return
    var uniform_set := _current_raymarch_uniform_set()
    if !uniform_set.is_valid():
        return
    var list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
    _rd.compute_list_bind_uniform_set(list, uniform_set, 0)
    var groups_x := int(ceil(float(width) / 8.0))
    var groups_y := int(ceil(float(height) / 8.0))
    _rd.compute_list_dispatch(list, groups_x, groups_y, 1)
    _rd.compute_list_end()
    if diag_enabled and diag_log_dispatch and (_debug_frame % max(1, diag_every) == 0):
        _diag("dispatch raymarch groups=(%d,%d,1) atlas_use_a=%s light_use_a=%s" % [
            groups_x, groups_y, str(_atlas_use_a), str(_light_use_a)
        ])

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
    var seeds := PackedInt32Array()
    seeds.resize(atlas.size())
    for i in range(seeds.size()):
        seeds[i] = 0

    var grid_extent := brick_grid * chunk_size
    var center := Vector3((grid_extent - 1) * 0.5, (grid_extent - 1) * 0.5, (grid_extent - 1) * 0.5)
    var fill_radius := float(grid_extent) * fill_radius_ratio
    var fill_radius_sq := fill_radius * fill_radius
    var entries := _load_voxel_entries(grid_extent)
    if entries.size() > 0:
        for entry in entries:
            var pos = entry.get("pos", Vector3.ZERO)
            var mat_id = int(entry.get("material", 1))
            if mat_id <= 0:
                continue
            var gx := int(pos.x)
            var gy := int(pos.y)
            var gz := int(pos.z)
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
            atlas[local_index] = mat_id
            var seed_val := int((gx * 73856093) ^ (gy * 19349663) ^ (gz * 83492791))
            if seed_val == 0:
                seed_val = 1
            seeds[local_index] = seed_val
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
                                var seed_val := int((gx * 73856093) ^ (gy * 19349663) ^ (gz * 83492791))
                                if seed_val == 0:
                                    seed_val = 1
                                seeds[local_index] = seed_val
                                any = true
                    if any:
                        occupancy[brick_index] = 1
                        indirection[brick_index] = brick_index + 1
                    else:
                        indirection[brick_index] = 0

    var ind_bytes := indirection.to_byte_array()
    _rd.buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes)
    _indirection_cpu = indirection
    var atlas_bytes := atlas.to_byte_array()
    if _atlas_a_rid.is_valid():
        _rd.buffer_update(_atlas_a_rid, 0, atlas_bytes.size(), atlas_bytes)
    if _atlas_b_rid.is_valid():
        _rd.buffer_update(_atlas_b_rid, 0, atlas_bytes.size(), atlas_bytes)
    var seed_bytes := seeds.to_byte_array()
    if _seed_a_rid.is_valid():
        _rd.buffer_update(_seed_a_rid, 0, seed_bytes.size(), seed_bytes)
    if _seed_b_rid.is_valid():
        _rd.buffer_update(_seed_b_rid, 0, seed_bytes.size(), seed_bytes)
    _atlas_use_a = true
    var occ_bytes := occupancy.to_byte_array()
    _rd.buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes)

func set_voxel_entries(entries: Array, allocate_all_bricks: bool = false) -> void:
    if _rd == null:
        return
    _active_list_ready = false
    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var indirection := PackedInt32Array()
    var occupancy := PackedInt32Array()
    indirection.resize(brick_count)
    occupancy.resize(brick_count)
    for i in range(brick_count):
        indirection[i] = (i + 1) if allocate_all_bricks else 0
        occupancy[i] = 0

    var atlas := PackedInt32Array()
    atlas.resize(brick_count * chunk_size * chunk_size * chunk_size)
    for i in range(atlas.size()):
        atlas[i] = 0
    var seeds := PackedInt32Array()
    seeds.resize(atlas.size())
    for i in range(seeds.size()):
        seeds[i] = 0

    var grid_extent := brick_grid * chunk_size
    for entry in entries:
        var pos = entry.get("pos", Vector3.ZERO)
        var mat_id = int(entry.get("material", 1))
        if mat_id <= 0:
            continue
        var gx := int(pos.x)
        var gy := int(pos.y)
        var gz := int(pos.z)
        if mat_id == 1:
            print("VoxelRenderer entries | sand pos=%s" % str(Vector3i(gx, gy, gz)))
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
        atlas[local_index] = mat_id
        if mat_id > 0:
            var seed_val := int(_rng.randi())
            if seed_val == 0:
                seed_val = 1
            seeds[local_index] = seed_val
        occupancy[brick_index] = 1
        if mat_id == 1:
            print("VoxelRenderer entries | wrote sand local_index=%d atlas_val=%d" % [local_index, atlas[local_index]])
        if !allocate_all_bricks:
            indirection[brick_index] = brick_index + 1

    var ind_bytes := indirection.to_byte_array()
    _rd.buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes)
    _indirection_cpu = indirection
    var atlas_bytes := atlas.to_byte_array()
    if _atlas_a_rid.is_valid():
        _rd.buffer_update(_atlas_a_rid, 0, atlas_bytes.size(), atlas_bytes)
    if _atlas_b_rid.is_valid():
        _rd.buffer_update(_atlas_b_rid, 0, atlas_bytes.size(), atlas_bytes)
    var seed_bytes: PackedByteArray = seeds.to_byte_array()
    if _seed_a_rid.is_valid():
        _rd.buffer_update(_seed_a_rid, 0, seed_bytes.size(), seed_bytes)
    if _seed_b_rid.is_valid():
        _rd.buffer_update(_seed_b_rid, 0, seed_bytes.size(), seed_bytes)
    _atlas_use_a = true
    var occ_bytes := occupancy.to_byte_array()
    _rd.buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes)
    if _light_a_rid.is_valid():
        _rd.buffer_clear(_light_a_rid, 0, _atlas_bytes)
    if _light_b_rid.is_valid():
        _rd.buffer_clear(_light_b_rid, 0, _atlas_bytes)
    if diag_enabled and diag_log_buffers:
        _diag("set_voxel_entries entries=%d allocate_all=%s grid=%d chunk=%d atlas_bytes=%d" % [
            entries.size(), str(allocate_all_bricks), brick_grid, chunk_size, _atlas_bytes
        ])

func _load_voxel_entries(grid_extent: int) -> Array:
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
    var entries: Array = []
    for entry in voxels:
        var arr := entry as Array
        if arr == null:
            continue
        if arr.size() < 3:
            continue
        var mat_id := 1
        if arr.size() >= 4:
            mat_id = int(arr[3])
        entries.append({
            "pos": Vector3(float(arr[0]), float(arr[1]), float(arr[2])),
            "material": mat_id
        })
    return entries

func _load_material_props() -> PackedByteArray:
    # Each material uses 8 floats:
    # [density, friction, viscosity, cohesion, drag, rest_cost, lateral_cost, gravity_bias]
    var defaults := {
        1: {"density": 1.6, "friction": 0.6, "viscosity": 0.2, "cohesion": 0.2, "drag": 0.3, "rest_cost": 0.35, "lateral_cost": 0.6, "gravity_bias": 1.4},
        2: {"density": 1.0, "friction": 0.1, "viscosity": 0.4, "cohesion": 0.05, "drag": 0.2, "rest_cost": 0.2, "lateral_cost": 0.35, "gravity_bias": 0.9},
        8: {"density": 2.5, "friction": 1.0, "viscosity": 1.0, "cohesion": 1.0, "drag": 1.0, "rest_cost": 10.0, "lateral_cost": 10.0, "gravity_bias": 0.0},
        9: {"density": 2.5, "friction": 1.0, "viscosity": 1.0, "cohesion": 1.0, "drag": 1.0, "rest_cost": 10.0, "lateral_cost": 10.0, "gravity_bias": 0.0}
    }
    var materials: Dictionary = {}
    var max_id := 9
    if !material_data_path.is_empty() and FileAccess.file_exists(material_data_path):
        var text := FileAccess.get_file_as_string(material_data_path)
        if !text.is_empty():
            var parsed: Variant = JSON.parse_string(text)
            if typeof(parsed) == TYPE_DICTIONARY:
                var parsed_dict: Dictionary = parsed
                var arr: Array = parsed_dict.get("materials", [])
                if typeof(arr) == TYPE_ARRAY:
                    for item in arr:
                        if typeof(item) != TYPE_DICTIONARY:
                            continue
                        var id := int(item.get("id", -1))
                        if id < 0:
                            continue
                        materials[id] = item
                        if id > max_id:
                            max_id = id
    for id in defaults.keys():
        if id > max_id:
            max_id = id
    var count := max_id + 1
    var floats := PackedFloat32Array()
    floats.resize(count * 8)
    for i in range(count):
        var src: Dictionary = materials.get(i, defaults.get(i, {}))
        if typeof(src) != TYPE_DICTIONARY:
            src = {}
        floats[i * 8 + 0] = float(src.get("density", 0.0))
        floats[i * 8 + 1] = float(src.get("friction", 0.0))
        floats[i * 8 + 2] = float(src.get("viscosity", 0.0))
        floats[i * 8 + 3] = float(src.get("cohesion", 0.0))
        floats[i * 8 + 4] = float(src.get("drag", 0.0))
        floats[i * 8 + 5] = float(src.get("rest_cost", 0.0))
        floats[i * 8 + 6] = float(src.get("lateral_cost", 0.0))
        floats[i * 8 + 7] = float(src.get("gravity_bias", 1.0))
    return floats.to_byte_array()

func _debug_log_snapshot(pos: Vector3, basis: Basis, world_extent: float) -> void:
    if !debug_logging:
        return
    var every: int = debug_log_every
    if every < 1:
        every = 1
    if _debug_frame % every != 0:
        return
    var grid_min := Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var grid_max := grid_min + Vector3.ONE * world_extent
    var cam_inside := (
        pos.x >= grid_min.x and pos.x <= grid_max.x
        and pos.y >= grid_min.y and pos.y <= grid_max.y
        and pos.z >= grid_min.z and pos.z <= grid_max.z
    )
    var forward := -basis.z
    var main_thread := true
    var pipeline_ok := _pipeline_rid.is_valid()
    print("VoxelRenderer debug | frame=%d main_thread=%s cam_pos=%s cam_fwd=%s cam_inside=%s render_ready=%s pipeline=%s probe=%s" % [
        _debug_frame,
        str(main_thread),
        str(pos),
        str(forward),
        str(cam_inside),
        str(_render_ready),
        str(pipeline_ok),
        str(debug_probe_enabled)
    ])
    if debug_render_thread_ping:
        RenderingServer.call_on_render_thread(Callable(self, "_debug_render_thread_ping").bind(_debug_frame))

func _debug_render_thread_ping(frame_id: int) -> void:
    var main_thread := true
    var rd_valid := _rd != null
    print("VoxelRenderer render thread | frame=%d main_thread=%s rd_valid=%s" % [
        frame_id,
        str(main_thread),
        str(rd_valid)
    ])

func _bcc_parity(cell: Vector3i) -> bool:
    return ((cell.x & 1) == (cell.y & 1)) and ((cell.y & 1) == (cell.z & 1))

func _current_atlas_rid() -> RID:
    return _atlas_a_rid if _atlas_use_a else _atlas_b_rid

func _atlas_index_for_cell(cell: Vector3i) -> int:
    if _indirection_cpu.is_empty():
        return -1
    var grid_extent := chunk_grid * chunk_size
    if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
        return -1
    var brick_size := chunk_size
    var bx := int(cell.x / brick_size)
    var by := int(cell.y / brick_size)
    var bz := int(cell.z / brick_size)
    if bx < 0 or by < 0 or bz < 0 or bx >= chunk_grid or by >= chunk_grid or bz >= chunk_grid:
        return -1
    var brick_index := bx + by * chunk_grid + bz * chunk_grid * chunk_grid
    if brick_index < 0 or brick_index >= _indirection_cpu.size():
        return -1
    var ind := _indirection_cpu[brick_index]
    if ind <= 0:
        return -1
    var lx := cell.x - bx * brick_size
    var ly := cell.y - by * brick_size
    var lz := cell.z - bz * brick_size
    var local_index := lx + ly * brick_size + lz * brick_size * brick_size
    var bricks_total := chunk_grid * chunk_grid * chunk_grid
    var atlas_size := bricks_total * brick_size * brick_size * brick_size
    var atlas_index := (ind - 1) * brick_size * brick_size * brick_size + local_index
    if atlas_index < 0 or atlas_index >= atlas_size:
        return -1
    return atlas_index

func get_cell_material(cell: Vector3i) -> int:
    if _rd == null:
        return 0
    var atlas_index := _atlas_index_for_cell(cell)
    if atlas_index < 0:
        return 0
    var atlas_rid := _current_atlas_rid()
    if !atlas_rid.is_valid():
        return 0
    var atlas_offset := atlas_index * 4
    var atlas_bytes := _rd.buffer_get_data(atlas_rid, atlas_offset, 4)
    if atlas_bytes.size() < 4:
        return 0
    var atlas_vals := atlas_bytes.to_int32_array()
    if atlas_vals.size() == 0:
        return 0
    return atlas_vals[0]

func set_voxel_at(cell: Vector3i, material: int) -> void:
    if _rd == null:
        return
    if !_bcc_parity(cell):
        print("VoxelRenderer set_voxel_at | non-bcc cell=%s" % str(cell))
    var atlas_index := _atlas_index_for_cell(cell)
    if atlas_index < 0:
        print("VoxelRenderer set_voxel_at | invalid cell=%s" % str(cell))
        return
    var bytes := PackedInt32Array([material]).to_byte_array()
    var offset := atlas_index * 4
    if _atlas_a_rid.is_valid():
        _rd.buffer_update(_atlas_a_rid, offset, bytes.size(), bytes)
    if _atlas_b_rid.is_valid():
        _rd.buffer_update(_atlas_b_rid, offset, bytes.size(), bytes)
    var seed_val := 0
    if material > 0:
        seed_val = int(_rng.randi())
        if seed_val == 0:
            seed_val = 1
    var seed_bytes := PackedInt32Array([seed_val]).to_byte_array()
    if _seed_a_rid.is_valid():
        _rd.buffer_update(_seed_a_rid, offset, seed_bytes.size(), seed_bytes)
    if _seed_b_rid.is_valid():
        _rd.buffer_update(_seed_b_rid, offset, seed_bytes.size(), seed_bytes)

func set_preview_cells(cells: Array) -> void:
    if _rd == null or !_preview_rid.is_valid():
        return
    # Clear previous preview cells
    if _preview_cells.size() > 0:
        var zero_bytes := PackedInt32Array([0]).to_byte_array()
        for cell in _preview_cells:
            if typeof(cell) != TYPE_VECTOR3I:
                continue
            var atlas_index := _atlas_index_for_cell(cell)
            if atlas_index < 0:
                continue
            var offset := atlas_index * 4
            _rd.buffer_update(_preview_rid, offset, zero_bytes.size(), zero_bytes)
    # Clear previous preview brick occupancy
    if _preview_occ_bricks.size() > 0 and _preview_occ_rid.is_valid():
        var zero_occ := PackedInt32Array([0]).to_byte_array()
        for brick_index in _preview_occ_bricks:
            var off := int(brick_index) * 4
            _rd.buffer_update(_preview_occ_rid, off, zero_occ.size(), zero_occ)
    _preview_cells = []
    _preview_occ_bricks = PackedInt32Array()
    if cells.size() == 0:
        return
    var one_bytes := PackedInt32Array([1]).to_byte_array()
    var one_occ := PackedInt32Array([1]).to_byte_array()
    var brick_set := {}
    for cell in cells:
        if typeof(cell) != TYPE_VECTOR3I:
            continue
        var atlas_index := _atlas_index_for_cell(cell)
        if atlas_index < 0:
            continue
        var offset := atlas_index * 4
        _rd.buffer_update(_preview_rid, offset, one_bytes.size(), one_bytes)
        _preview_cells.append(cell)
        if _preview_occ_rid.is_valid():
            var bx := int(cell.x / chunk_size)
            var by := int(cell.y / chunk_size)
            var bz := int(cell.z / chunk_size)
            var brick_index := bx + by * chunk_grid + bz * chunk_grid * chunk_grid
            var key := str(brick_index)
            if !brick_set.has(key):
                brick_set[key] = true
                _rd.buffer_update(_preview_occ_rid, brick_index * 4, one_occ.size(), one_occ)
                _preview_occ_bricks.append(brick_index)

func set_cursor_cell(cell: Vector3i) -> void:
    if _rd == null or !_cursor_rid.is_valid():
        return
    if _cursor_cell.x >= 0:
        var old_index := _atlas_index_for_cell(_cursor_cell)
        if old_index >= 0:
            var zero_bytes := PackedInt32Array([0]).to_byte_array()
            _rd.buffer_update(_cursor_rid, old_index * 4, zero_bytes.size(), zero_bytes)
    _cursor_cell = cell
    if _cursor_cell.x < 0:
        return
    var atlas_index := _atlas_index_for_cell(_cursor_cell)
    if atlas_index < 0:
        return
    var one_bytes := PackedInt32Array([1]).to_byte_array()
    _rd.buffer_update(_cursor_rid, atlas_index * 4, one_bytes.size(), one_bytes)

func set_debug_probe_cell_xyz(x: int, y: int, z: int) -> void:
    debug_probe_cell = Vector3i(x, y, z)

func _debug_request_probe() -> void:
    if !debug_probe_enabled:
        return
    var every: int = debug_probe_every
    if every < 1:
        every = 1
    _debug_probe_frame += 1
    if _debug_probe_frame % every != 0:
        return
    if _indirection_cpu.is_empty():
        print("VoxelRenderer probe | frame=%d indirection_cpu=empty" % _debug_frame)
        return
    var grid_extent := chunk_grid * chunk_size
    var cell := debug_probe_cell
    var parity := _bcc_parity(cell)
    var in_bounds := (
        cell.x >= 0 and cell.y >= 0 and cell.z >= 0
        and cell.x < grid_extent and cell.y < grid_extent and cell.z < grid_extent
    )
    if !in_bounds:
        print("VoxelRenderer probe | frame=%d cell=%s out_of_bounds grid_extent=%d parity=%s" % [
            _debug_frame,
            str(cell),
            grid_extent,
            str(parity)
        ])
        return
    var brick_size := chunk_size
    var bx := int(cell.x / brick_size)
    var by := int(cell.y / brick_size)
    var bz := int(cell.z / brick_size)
    if bx < 0 or by < 0 or bz < 0 or bx >= chunk_grid or by >= chunk_grid or bz >= chunk_grid:
        print("VoxelRenderer probe | frame=%d cell=%s brick_out_of_bounds brick=%s" % [
            _debug_frame,
            str(cell),
            str(Vector3i(bx, by, bz))
        ])
        return
    var brick_index := bx + by * chunk_grid + bz * chunk_grid * chunk_grid
    if brick_index < 0 or brick_index >= _indirection_cpu.size():
        print("VoxelRenderer probe | frame=%d cell=%s brick_index_out_of_range=%d" % [
            _debug_frame,
            str(cell),
            brick_index
        ])
        return
    var ind := _indirection_cpu[brick_index]
    if ind <= 0:
        print("VoxelRenderer probe | frame=%d cell=%s parity=%s ind=%d brick_index=%d" % [
            _debug_frame,
            str(cell),
            str(parity),
            ind,
            brick_index
        ])
        return
    var lx := cell.x - bx * brick_size
    var ly := cell.y - by * brick_size
    var lz := cell.z - bz * brick_size
    var local_index := lx + ly * brick_size + lz * brick_size * brick_size
    var bricks_total := chunk_grid * chunk_grid * chunk_grid
    var atlas_size := bricks_total * brick_size * brick_size * brick_size
    var atlas_index := (ind - 1) * brick_size * brick_size * brick_size + local_index
    if atlas_index < 0 or atlas_index >= atlas_size:
        print("VoxelRenderer probe | frame=%d cell=%s atlas_index_out_of_range=%d size=%d" % [
            _debug_frame,
            str(cell),
            atlas_index,
            atlas_size
        ])
        return
    var atlas_offset := atlas_index * 4
    var occ_offset := brick_index * 4
    var atlas_rid := _current_atlas_rid()
    RenderingServer.call_on_render_thread(Callable(self, "_debug_probe_readback_on_render_thread").bind(
        _debug_frame,
        cell,
        parity,
        ind,
        atlas_index,
        atlas_offset,
        occ_offset,
        atlas_rid
    ))

func _debug_probe_readback_on_render_thread(frame_id: int, cell: Vector3i, parity: bool, ind: int, atlas_index: int, atlas_offset: int, occ_offset: int, atlas_rid: RID) -> void:
    if _rd == null:
        return
    if !atlas_rid.is_valid():
        return
    var atlas_bytes := _rd.buffer_get_data(atlas_rid, atlas_offset, 4)
    var occ_bytes := PackedByteArray()
    if _occupancy_rid.is_valid():
        occ_bytes = _rd.buffer_get_data(_occupancy_rid, occ_offset, 4)
    if atlas_bytes.size() < 4:
        return
    var atlas_vals := atlas_bytes.to_int32_array()
    var atlas_val := atlas_vals[0] if atlas_vals.size() > 0 else 0
    var occ_val := 0
    if occ_bytes.size() >= 4:
        var occ_vals := occ_bytes.to_int32_array()
        occ_val = occ_vals[0] if occ_vals.size() > 0 else 0
    var main_thread := true
    print("VoxelRenderer probe | frame=%d cell=%s parity=%s ind=%d atlas_index=%d atlas_val=%d occ_val=%d main_thread=%s" % [
        frame_id,
        str(cell),
        str(parity),
        ind,
        atlas_index,
        atlas_val,
        occ_val,
        str(main_thread)
    ])

func debug_scan_column(x: int, z: int, y0: int, y1: int) -> void:
    if _rd == null or _indirection_cpu.is_empty():
        print("VoxelRenderer scan | rd/indirection unavailable")
        return
    var grid_extent: int = chunk_grid * chunk_size
    var ys: int = int(clamp(y0, 0, grid_extent - 1))
    var ye: int = int(clamp(y1, 0, grid_extent - 1))
    if ys > ye:
        var tmp: int = ys
        ys = ye
        ye = tmp
    var atlas_rid := _current_atlas_rid()
    if !atlas_rid.is_valid():
        print("VoxelRenderer scan | atlas rid invalid")
        return
    for y in range(ys, ye + 1):
        var gx := x
        var gy := y
        var gz := z
        if gx < 0 or gy < 0 or gz < 0 or gx >= grid_extent or gy >= grid_extent or gz >= grid_extent:
            continue
        if !((gx & 1) == (gy & 1) and (gy & 1) == (gz & 1)):
            continue
        var bx: int = gx / chunk_size
        var by: int = gy / chunk_size
        var bz: int = gz / chunk_size
        var brick_index: int = bx + by * chunk_grid + bz * chunk_grid * chunk_grid
        if brick_index < 0 or brick_index >= _indirection_cpu.size():
            continue
        var ind: int = _indirection_cpu[brick_index]
        if ind <= 0:
            continue
        var lx: int = gx - bx * chunk_size
        var ly: int = gy - by * chunk_size
        var lz: int = gz - bz * chunk_size
        var local_index: int = lx + ly * chunk_size + lz * chunk_size * chunk_size
        var atlas_index: int = (ind - 1) * chunk_size * chunk_size * chunk_size + local_index
        var atlas_offset: int = atlas_index * 4
        var atlas_bytes := _rd.buffer_get_data(atlas_rid, atlas_offset, 4)
        if atlas_bytes.size() < 4:
            continue
        var atlas_vals := atlas_bytes.to_int32_array()
        var atlas_val := atlas_vals[0] if atlas_vals.size() > 0 else 0
        if atlas_val != 0:
            print("VoxelRenderer scan | hit cell=%s atlas_val=%d" % [str(Vector3i(gx, gy, gz)), atlas_val])
            return
    print("VoxelRenderer scan | no hits in column x=%d z=%d y=%d..%d" % [x, z, ys, ye])

func debug_scan_any(max_checks: int = 5000) -> void:
    if _rd == null or _indirection_cpu.is_empty():
        print("VoxelRenderer scan_any | rd/indirection unavailable")
        return
    var grid_extent: int = chunk_grid * chunk_size
    var atlas_rid := _current_atlas_rid()
    if !atlas_rid.is_valid():
        print("VoxelRenderer scan_any | atlas rid invalid")
        return
    var checks := 0
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if checks >= max_checks:
                    print("VoxelRenderer scan_any | no hits in first %d checks" % max_checks)
                    return
                checks += 1
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var bx: int = x / chunk_size
                var by: int = y / chunk_size
                var bz: int = z / chunk_size
                var brick_index: int = bx + by * chunk_grid + bz * chunk_grid * chunk_grid
                if brick_index < 0 or brick_index >= _indirection_cpu.size():
                    continue
                var ind: int = _indirection_cpu[brick_index]
                if ind <= 0:
                    continue
                var lx: int = x - bx * chunk_size
                var ly: int = y - by * chunk_size
                var lz: int = z - bz * chunk_size
                var local_index: int = lx + ly * chunk_size + lz * chunk_size * chunk_size
                var atlas_index: int = (ind - 1) * chunk_size * chunk_size * chunk_size + local_index
                var atlas_offset: int = atlas_index * 4
                var atlas_bytes := _rd.buffer_get_data(atlas_rid, atlas_offset, 4)
                if atlas_bytes.size() < 4:
                    continue
                var atlas_vals := atlas_bytes.to_int32_array()
                var atlas_val := atlas_vals[0] if atlas_vals.size() > 0 else 0
                if atlas_val != 0:
                    print("VoxelRenderer scan_any | hit cell=%s atlas_val=%d" % [str(Vector3i(x, y, z)), atlas_val])
                    return
    print("VoxelRenderer scan_any | no hits in scan")

func debug_scan_for_material(mat_id: int, max_checks: int = 200000) -> void:
    if _rd == null or _indirection_cpu.is_empty():
        print("VoxelRenderer scan_mat | rd/indirection unavailable")
        return
    var grid_extent: int = chunk_grid * chunk_size
    var atlas_rid := _current_atlas_rid()
    if !atlas_rid.is_valid():
        print("VoxelRenderer scan_mat | atlas rid invalid")
        return
    var checks := 0
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if checks >= max_checks:
                    print("VoxelRenderer scan_mat | no hits in first %d checks for mat=%d" % [max_checks, mat_id])
                    return
                checks += 1
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var bx: int = x / chunk_size
                var by: int = y / chunk_size
                var bz: int = z / chunk_size
                var brick_index: int = bx + by * chunk_grid + bz * chunk_grid * chunk_grid
                if brick_index < 0 or brick_index >= _indirection_cpu.size():
                    continue
                var ind: int = _indirection_cpu[brick_index]
                if ind <= 0:
                    continue
                var lx: int = x - bx * chunk_size
                var ly: int = y - by * chunk_size
                var lz: int = z - bz * chunk_size
                var local_index: int = lx + ly * chunk_size + lz * chunk_size * chunk_size
                var atlas_index: int = (ind - 1) * chunk_size * chunk_size * chunk_size + local_index
                var atlas_offset: int = atlas_index * 4
                var atlas_bytes := _rd.buffer_get_data(atlas_rid, atlas_offset, 4)
                if atlas_bytes.size() < 4:
                    continue
                var atlas_vals := atlas_bytes.to_int32_array()
                var atlas_val := atlas_vals[0] if atlas_vals.size() > 0 else 0
                if atlas_val == mat_id:
                    print("VoxelRenderer scan_mat | hit cell=%s atlas_val=%d" % [str(Vector3i(x, y, z)), atlas_val])
                    return
    print("VoxelRenderer scan_mat | no hits for mat=%d" % mat_id)

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
    if _uniform_set_a_light_a_rid.is_valid():
        _rd.free_rid(_uniform_set_a_light_a_rid)
    if _uniform_set_a_light_b_rid.is_valid():
        _rd.free_rid(_uniform_set_a_light_b_rid)
    if _uniform_set_b_light_a_rid.is_valid():
        _rd.free_rid(_uniform_set_b_light_a_rid)
    if _uniform_set_b_light_b_rid.is_valid():
        _rd.free_rid(_uniform_set_b_light_b_rid)
    if _occupancy_uniform_set_a_rid.is_valid():
        _rd.free_rid(_occupancy_uniform_set_a_rid)
    if _occupancy_uniform_set_b_rid.is_valid():
        _rd.free_rid(_occupancy_uniform_set_b_rid)
    if _sim_uniform_set_ab.is_valid():
        _rd.free_rid(_sim_uniform_set_ab)
    if _sim_uniform_set_ba.is_valid():
        _rd.free_rid(_sim_uniform_set_ba)
    if _active_list_uniform_set_rid.is_valid():
        _rd.free_rid(_active_list_uniform_set_rid)
    if _active_dispatch_uniform_set_rid.is_valid():
        _rd.free_rid(_active_dispatch_uniform_set_rid)
    if _light_uniform_set_a_ab.is_valid():
        _rd.free_rid(_light_uniform_set_a_ab)
    if _light_uniform_set_a_ba.is_valid():
        _rd.free_rid(_light_uniform_set_a_ba)
    if _light_uniform_set_b_ab.is_valid():
        _rd.free_rid(_light_uniform_set_b_ab)
    if _light_uniform_set_b_ba.is_valid():
        _rd.free_rid(_light_uniform_set_b_ba)
    if _ubo_rid.is_valid():
        _rd.free_rid(_ubo_rid)
    if _texture_rid.is_valid():
        _rd.free_rid(_texture_rid)
    if _indirection_rid.is_valid():
        _rd.free_rid(_indirection_rid)
    if _atlas_a_rid.is_valid():
        _rd.free_rid(_atlas_a_rid)
    if _atlas_b_rid.is_valid():
        _rd.free_rid(_atlas_b_rid)
    if _seed_a_rid.is_valid():
        _rd.free_rid(_seed_a_rid)
    if _seed_b_rid.is_valid():
        _rd.free_rid(_seed_b_rid)
    if _preview_rid.is_valid():
        _rd.free_rid(_preview_rid)
    if _cursor_rid.is_valid():
        _rd.free_rid(_cursor_rid)
    if _preview_occ_rid.is_valid():
        _rd.free_rid(_preview_occ_rid)
    if _light_a_rid.is_valid():
        _rd.free_rid(_light_a_rid)
    if _light_b_rid.is_valid():
        _rd.free_rid(_light_b_rid)
    if _occupancy_rid.is_valid():
        _rd.free_rid(_occupancy_rid)
    if _metrics_rid.is_valid():
        _rd.free_rid(_metrics_rid)
    if _active_list_rid.is_valid():
        _rd.free_rid(_active_list_rid)
    if _active_count_rid.is_valid():
        _rd.free_rid(_active_count_rid)
    if _sim_dispatch_rid.is_valid():
        _rd.free_rid(_sim_dispatch_rid)
    if _material_props_rid.is_valid():
        _rd.free_rid(_material_props_rid)
    if _pipeline_rid.is_valid():
        _rd.free_rid(_pipeline_rid)
    if _shader_rid.is_valid():
        _rd.free_rid(_shader_rid)
    if _occupancy_pipeline_rid.is_valid():
        _rd.free_rid(_occupancy_pipeline_rid)
    if _occupancy_shader_rid.is_valid():
        _rd.free_rid(_occupancy_shader_rid)
    if _sim_pipeline_rid.is_valid():
        _rd.free_rid(_sim_pipeline_rid)
    if _sim_shader_rid.is_valid():
        _rd.free_rid(_sim_shader_rid)
    if _light_pipeline_rid.is_valid():
        _rd.free_rid(_light_pipeline_rid)
    if _light_shader_rid.is_valid():
        _rd.free_rid(_light_shader_rid)
    if _active_list_pipeline_rid.is_valid():
        _rd.free_rid(_active_list_pipeline_rid)
    if _active_list_shader_rid.is_valid():
        _rd.free_rid(_active_list_shader_rid)
    if _active_dispatch_pipeline_rid.is_valid():
        _rd.free_rid(_active_dispatch_pipeline_rid)
    if _active_dispatch_shader_rid.is_valid():
        _rd.free_rid(_active_dispatch_shader_rid)
