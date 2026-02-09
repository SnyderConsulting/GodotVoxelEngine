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
@export var sim_mode: int = 1 # 1 = MPM (particles), 0 = legacy CA (grid)
@export var mpm_dt: float = 1.0 / 60.0
@export var mpm_substeps: int = 2
@export var mpm_max_particles: int = 50000
@export var mpm_gravity_strength: float = 12.0
@export var mpm_rigid_enabled: bool = true
@export var mpm_fracture_enabled: bool = true
@export var mpm_ccl_iterations: int = 12
@export var mpm_stats_enabled: bool = false
@export var mpm_stats_every: int = 30
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
var _mpm_copy_static_shader_rid: RID
var _mpm_copy_static_pipeline_rid: RID
var _mpm_init_particles_shader_rid: RID
var _mpm_init_particles_pipeline_rid: RID
var _mpm_p2g_shader_rid: RID
var _mpm_p2g_pipeline_rid: RID
var _mpm_grid_update_shader_rid: RID
var _mpm_grid_update_pipeline_rid: RID
var _mpm_g2p_advect_shader_rid: RID
var _mpm_g2p_advect_pipeline_rid: RID
var _mpm_grid_to_atlas_shader_rid: RID
var _mpm_grid_to_atlas_pipeline_rid: RID
var _mpm_particles_to_atlas_shader_rid: RID
var _mpm_particles_to_atlas_pipeline_rid: RID
var _mpm_build_rigid_map_shader_rid: RID
var _mpm_build_rigid_map_pipeline_rid: RID
var _mpm_update_bonds_shader_rid: RID
var _mpm_update_bonds_pipeline_rid: RID
var _mpm_ccl_init_shader_rid: RID
var _mpm_ccl_init_pipeline_rid: RID
var _mpm_ccl_propagate_shader_rid: RID
var _mpm_ccl_propagate_pipeline_rid: RID
var _mpm_ccl_write_shader_rid: RID
var _mpm_ccl_write_pipeline_rid: RID
var _mpm_island_accum0_shader_rid: RID
var _mpm_island_accum0_pipeline_rid: RID
var _mpm_island_finalize_shader_rid: RID
var _mpm_island_finalize_pipeline_rid: RID
var _mpm_island_accum1_shader_rid: RID
var _mpm_island_accum1_pipeline_rid: RID
var _mpm_island_apply_shader_rid: RID
var _mpm_island_apply_pipeline_rid: RID
var _mpm_stats_init_shader_rid: RID
var _mpm_stats_init_pipeline_rid: RID
var _mpm_stats_shader_rid: RID
var _mpm_stats_pipeline_rid: RID
var _texture_rid: RID
var _ubo_rid: RID
var _indirection_rid: RID
var _atlas_a_rid: RID
var _atlas_b_rid: RID
var _atlas_static_rid: RID
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
var _mpm_pos_mass_a_rid: RID
var _mpm_pos_mass_b_rid: RID
var _mpm_vel_vol_a_rid: RID
var _mpm_vel_vol_b_rid: RID
var _mpm_c_a_rid: RID
var _mpm_c_b_rid: RID
var _mpm_f_a_rid: RID
var _mpm_f_b_rid: RID
var _mpm_meta_rid: RID
var _mpm_particle_count_rid: RID
var _mpm_grid_accum_rid: RID
var _mpm_grid_vel_rid: RID
var _mpm_rigid_map_rid: RID
var _mpm_cell_pos_rid: RID
var _mpm_labels_a_rid: RID
var _mpm_labels_b_rid: RID
var _mpm_island_mass_mom_rid: RID
var _mpm_island_mass_com_rid: RID
var _mpm_island_com_mass_rid: RID
var _mpm_island_vel_rid: RID
var _mpm_island_L_rid: RID
var _mpm_island_I0_rid: RID
var _mpm_island_I1_rid: RID
var _mpm_stats_rid: RID
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
var _mpm_copy_uniform_set_a: RID
var _mpm_copy_uniform_set_b: RID
var _mpm_init_uniform_set: RID
var _mpm_p2g_uniform_set_a: RID
var _mpm_p2g_uniform_set_b: RID
var _mpm_grid_uniform_set: RID
var _mpm_g2p_uniform_set_ab: RID
var _mpm_g2p_uniform_set_ba: RID
var _mpm_grid_to_atlas_uniform_set_a: RID
var _mpm_grid_to_atlas_uniform_set_b: RID
var _mpm_particles_to_atlas_uniform_set_a: RID
var _mpm_particles_to_atlas_uniform_set_b: RID
var _mpm_rigid_map_set_a: RID
var _mpm_rigid_map_set_b: RID
var _mpm_update_bonds_set_a: RID
var _mpm_update_bonds_set_b: RID
var _mpm_ccl_init_set_a: RID
var _mpm_ccl_init_set_b: RID
var _mpm_ccl_prop_set_a_ab: RID
var _mpm_ccl_prop_set_a_ba: RID
var _mpm_ccl_prop_set_b_ab: RID
var _mpm_ccl_prop_set_b_ba: RID
var _mpm_ccl_write_set_a: RID
var _mpm_ccl_write_set_b: RID
var _mpm_island_accum0_set_a: RID
var _mpm_island_accum0_set_b: RID
var _mpm_island_finalize_set: RID
var _mpm_island_accum1_set_a: RID
var _mpm_island_accum1_set_b: RID
var _mpm_island_apply_set_a: RID
var _mpm_island_apply_set_b: RID
var _mpm_stats_init_set: RID
var _mpm_stats_set_a: RID
var _mpm_stats_set_b: RID
var _active_list_uniform_set_rid: RID
var _active_dispatch_uniform_set_rid: RID
var _light_uniform_set_a_ab: RID
var _light_uniform_set_a_ba: RID
var _light_uniform_set_b_ab: RID
var _light_uniform_set_b_ba: RID
var _occupancy_bytes := 0
var _metrics_bytes := 0
var _mpm_stats_bytes := 0
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
var _mpm_stats_frame := 0
var _mpm_stats_last_readback := 0
var _debug_frame := 0
var _debug_probe_frame := 0
var _sim_frame := 0
var _atlas_use_a := true
var _light_use_a := true
var _light_frame := 0
var _active_list_ready := false
var _indirection_cpu: PackedInt32Array = PackedInt32Array()
var _rng := RandomNumberGenerator.new()
var _mpm_particles_use_a := true
var _mpm_particle_count_cpu: int = 0
var _mpm_islands_ready := false
var _material_mass_by_id: Dictionary = {}
var mpm_last_stats_frame: int = 0
var mpm_last_stats_raw: PackedInt32Array = PackedInt32Array()
var mpm_last_stats: Dictionary = {}

func _diag(msg: String) -> void:
    if !diag_enabled:
        return
    print("VoxelRenderer diag | frame=%d %s" % [_debug_frame, msg])

func mpm_get_last_stats_frame() -> int:
    return mpm_last_stats_frame

func mpm_get_last_stats_raw() -> Array:
    # Automation server serializes Packed*Arrays inconsistently across builds.
    # Return a plain Array[int] for reliable JSON transport.
    var out: Array = []
    var n := mpm_last_stats_raw.size()
    out.resize(n)
    for i in range(n):
        out[i] = int(mpm_last_stats_raw[i])
    return out

func mpm_get_last_stats() -> Dictionary:
    return mpm_last_stats

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

    # MPM (particle) physics pipelines.
    _mpm_copy_static_shader_rid = RID()
    _mpm_copy_static_pipeline_rid = RID()
    var mpm_copy_text := FileAccess.get_file_as_string("res://shaders/mpm_copy_static.glsl")
    if !mpm_copy_text.is_empty():
        var mpm_copy_source := RDShaderSource.new()
        mpm_copy_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_copy_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_copy_text)
        var mpm_copy_spirv := _rd.shader_compile_spirv_from_source(mpm_copy_source)
        var mpm_copy_error := mpm_copy_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_copy_error != "":
            push_error("MPM copy_static shader compile error: %s" % mpm_copy_error)
        else:
            _mpm_copy_static_shader_rid = _rd.shader_create_from_spirv(mpm_copy_spirv)
            if !_mpm_copy_static_shader_rid.is_valid():
                push_error("Failed to create MPM copy_static shader.")
            else:
                _mpm_copy_static_pipeline_rid = _rd.compute_pipeline_create(_mpm_copy_static_shader_rid)
                if !_mpm_copy_static_pipeline_rid.is_valid():
                    push_error("Failed to create MPM copy_static pipeline.")

    _mpm_init_particles_shader_rid = RID()
    _mpm_init_particles_pipeline_rid = RID()
    var mpm_init_text := FileAccess.get_file_as_string("res://shaders/mpm_init_particles.glsl")
    if !mpm_init_text.is_empty():
        var mpm_init_source := RDShaderSource.new()
        mpm_init_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_init_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_init_text)
        var mpm_init_spirv := _rd.shader_compile_spirv_from_source(mpm_init_source)
        var mpm_init_error := mpm_init_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_init_error != "":
            push_error("MPM init_particles shader compile error: %s" % mpm_init_error)
        else:
            _mpm_init_particles_shader_rid = _rd.shader_create_from_spirv(mpm_init_spirv)
            if !_mpm_init_particles_shader_rid.is_valid():
                push_error("Failed to create MPM init_particles shader.")
            else:
                _mpm_init_particles_pipeline_rid = _rd.compute_pipeline_create(_mpm_init_particles_shader_rid)
                if !_mpm_init_particles_pipeline_rid.is_valid():
                    push_error("Failed to create MPM init_particles pipeline.")

    _mpm_p2g_shader_rid = RID()
    _mpm_p2g_pipeline_rid = RID()
    var mpm_p2g_text := FileAccess.get_file_as_string("res://shaders/mpm_p2g.glsl")
    if !mpm_p2g_text.is_empty():
        var mpm_p2g_source := RDShaderSource.new()
        mpm_p2g_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_p2g_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_p2g_text)
        var mpm_p2g_spirv := _rd.shader_compile_spirv_from_source(mpm_p2g_source)
        var mpm_p2g_error := mpm_p2g_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_p2g_error != "":
            push_error("MPM p2g shader compile error: %s" % mpm_p2g_error)
        else:
            _mpm_p2g_shader_rid = _rd.shader_create_from_spirv(mpm_p2g_spirv)
            if !_mpm_p2g_shader_rid.is_valid():
                push_error("Failed to create MPM p2g shader.")
            else:
                _mpm_p2g_pipeline_rid = _rd.compute_pipeline_create(_mpm_p2g_shader_rid)
                if !_mpm_p2g_pipeline_rid.is_valid():
                    push_error("Failed to create MPM p2g pipeline.")

    _mpm_grid_update_shader_rid = RID()
    _mpm_grid_update_pipeline_rid = RID()
    var mpm_grid_text := FileAccess.get_file_as_string("res://shaders/mpm_grid_update.glsl")
    if !mpm_grid_text.is_empty():
        var mpm_grid_source := RDShaderSource.new()
        mpm_grid_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_grid_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_grid_text)
        var mpm_grid_spirv := _rd.shader_compile_spirv_from_source(mpm_grid_source)
        var mpm_grid_error := mpm_grid_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_grid_error != "":
            push_error("MPM grid_update shader compile error: %s" % mpm_grid_error)
        else:
            _mpm_grid_update_shader_rid = _rd.shader_create_from_spirv(mpm_grid_spirv)
            if !_mpm_grid_update_shader_rid.is_valid():
                push_error("Failed to create MPM grid_update shader.")
            else:
                _mpm_grid_update_pipeline_rid = _rd.compute_pipeline_create(_mpm_grid_update_shader_rid)
                if !_mpm_grid_update_pipeline_rid.is_valid():
                    push_error("Failed to create MPM grid_update pipeline.")

    _mpm_g2p_advect_shader_rid = RID()
    _mpm_g2p_advect_pipeline_rid = RID()
    var mpm_g2p_text := FileAccess.get_file_as_string("res://shaders/mpm_g2p_advect.glsl")
    if !mpm_g2p_text.is_empty():
        var mpm_g2p_source := RDShaderSource.new()
        mpm_g2p_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_g2p_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_g2p_text)
        var mpm_g2p_spirv := _rd.shader_compile_spirv_from_source(mpm_g2p_source)
        var mpm_g2p_error := mpm_g2p_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_g2p_error != "":
            push_error("MPM g2p_advect shader compile error: %s" % mpm_g2p_error)
        else:
            _mpm_g2p_advect_shader_rid = _rd.shader_create_from_spirv(mpm_g2p_spirv)
            if !_mpm_g2p_advect_shader_rid.is_valid():
                push_error("Failed to create MPM g2p_advect shader.")
            else:
                _mpm_g2p_advect_pipeline_rid = _rd.compute_pipeline_create(_mpm_g2p_advect_shader_rid)
                if !_mpm_g2p_advect_pipeline_rid.is_valid():
                    push_error("Failed to create MPM g2p_advect pipeline.")

    _mpm_grid_to_atlas_shader_rid = RID()
    _mpm_grid_to_atlas_pipeline_rid = RID()
    var mpm_grid_to_atlas_text := FileAccess.get_file_as_string("res://shaders/mpm_grid_to_atlas.glsl")
    if !mpm_grid_to_atlas_text.is_empty():
        var mpm_grid_to_atlas_source := RDShaderSource.new()
        mpm_grid_to_atlas_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_grid_to_atlas_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_grid_to_atlas_text)
        var mpm_grid_to_atlas_spirv := _rd.shader_compile_spirv_from_source(mpm_grid_to_atlas_source)
        var mpm_grid_to_atlas_error := mpm_grid_to_atlas_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_grid_to_atlas_error != "":
            push_error("MPM grid_to_atlas shader compile error: %s" % mpm_grid_to_atlas_error)
        else:
            _mpm_grid_to_atlas_shader_rid = _rd.shader_create_from_spirv(mpm_grid_to_atlas_spirv)
            if !_mpm_grid_to_atlas_shader_rid.is_valid():
                push_error("Failed to create MPM grid_to_atlas shader.")
            else:
                _mpm_grid_to_atlas_pipeline_rid = _rd.compute_pipeline_create(_mpm_grid_to_atlas_shader_rid)
                if !_mpm_grid_to_atlas_pipeline_rid.is_valid():
                    push_error("Failed to create MPM grid_to_atlas pipeline.")

    _mpm_particles_to_atlas_shader_rid = RID()
    _mpm_particles_to_atlas_pipeline_rid = RID()
    var mpm_particles_to_atlas_text := FileAccess.get_file_as_string("res://shaders/mpm_particles_to_atlas.glsl")
    if !mpm_particles_to_atlas_text.is_empty():
        var mpm_particles_to_atlas_source := RDShaderSource.new()
        mpm_particles_to_atlas_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_particles_to_atlas_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_particles_to_atlas_text)
        var mpm_particles_to_atlas_spirv := _rd.shader_compile_spirv_from_source(mpm_particles_to_atlas_source)
        var mpm_particles_to_atlas_error := mpm_particles_to_atlas_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_particles_to_atlas_error != "":
            push_error("MPM particles_to_atlas shader compile error: %s" % mpm_particles_to_atlas_error)
        else:
            _mpm_particles_to_atlas_shader_rid = _rd.shader_create_from_spirv(mpm_particles_to_atlas_spirv)
            if !_mpm_particles_to_atlas_shader_rid.is_valid():
                push_error("Failed to create MPM particles_to_atlas shader.")
            else:
                _mpm_particles_to_atlas_pipeline_rid = _rd.compute_pipeline_create(_mpm_particles_to_atlas_shader_rid)
                if !_mpm_particles_to_atlas_pipeline_rid.is_valid():
                    push_error("Failed to create MPM particles_to_atlas pipeline.")

    _mpm_build_rigid_map_shader_rid = RID()
    _mpm_build_rigid_map_pipeline_rid = RID()
    var mpm_rigid_map_text := FileAccess.get_file_as_string("res://shaders/mpm_build_rigid_map.glsl")
    if !mpm_rigid_map_text.is_empty():
        var mpm_rigid_map_source := RDShaderSource.new()
        mpm_rigid_map_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_rigid_map_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_rigid_map_text)
        var mpm_rigid_map_spirv := _rd.shader_compile_spirv_from_source(mpm_rigid_map_source)
        var mpm_rigid_map_error := mpm_rigid_map_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_rigid_map_error != "":
            push_error("MPM build_rigid_map shader compile error: %s" % mpm_rigid_map_error)
        else:
            _mpm_build_rigid_map_shader_rid = _rd.shader_create_from_spirv(mpm_rigid_map_spirv)
            if !_mpm_build_rigid_map_shader_rid.is_valid():
                push_error("Failed to create MPM build_rigid_map shader.")
            else:
                _mpm_build_rigid_map_pipeline_rid = _rd.compute_pipeline_create(_mpm_build_rigid_map_shader_rid)
                if !_mpm_build_rigid_map_pipeline_rid.is_valid():
                    push_error("Failed to create MPM build_rigid_map pipeline.")

    _mpm_update_bonds_shader_rid = RID()
    _mpm_update_bonds_pipeline_rid = RID()
    var mpm_update_bonds_text := FileAccess.get_file_as_string("res://shaders/mpm_update_bonds.glsl")
    if !mpm_update_bonds_text.is_empty():
        var mpm_update_bonds_source := RDShaderSource.new()
        mpm_update_bonds_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_update_bonds_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_update_bonds_text)
        var mpm_update_bonds_spirv := _rd.shader_compile_spirv_from_source(mpm_update_bonds_source)
        var mpm_update_bonds_error := mpm_update_bonds_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_update_bonds_error != "":
            push_error("MPM update_bonds shader compile error: %s" % mpm_update_bonds_error)
        else:
            _mpm_update_bonds_shader_rid = _rd.shader_create_from_spirv(mpm_update_bonds_spirv)
            if !_mpm_update_bonds_shader_rid.is_valid():
                push_error("Failed to create MPM update_bonds shader.")
            else:
                _mpm_update_bonds_pipeline_rid = _rd.compute_pipeline_create(_mpm_update_bonds_shader_rid)
                if !_mpm_update_bonds_pipeline_rid.is_valid():
                    push_error("Failed to create MPM update_bonds pipeline.")

    _mpm_ccl_init_shader_rid = RID()
    _mpm_ccl_init_pipeline_rid = RID()
    var mpm_ccl_init_text := FileAccess.get_file_as_string("res://shaders/mpm_ccl_init.glsl")
    if !mpm_ccl_init_text.is_empty():
        var mpm_ccl_init_source := RDShaderSource.new()
        mpm_ccl_init_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_ccl_init_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_ccl_init_text)
        var mpm_ccl_init_spirv := _rd.shader_compile_spirv_from_source(mpm_ccl_init_source)
        var mpm_ccl_init_error := mpm_ccl_init_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_ccl_init_error != "":
            push_error("MPM ccl_init shader compile error: %s" % mpm_ccl_init_error)
        else:
            _mpm_ccl_init_shader_rid = _rd.shader_create_from_spirv(mpm_ccl_init_spirv)
            if !_mpm_ccl_init_shader_rid.is_valid():
                push_error("Failed to create MPM ccl_init shader.")
            else:
                _mpm_ccl_init_pipeline_rid = _rd.compute_pipeline_create(_mpm_ccl_init_shader_rid)
                if !_mpm_ccl_init_pipeline_rid.is_valid():
                    push_error("Failed to create MPM ccl_init pipeline.")

    _mpm_ccl_propagate_shader_rid = RID()
    _mpm_ccl_propagate_pipeline_rid = RID()
    var mpm_ccl_prop_text := FileAccess.get_file_as_string("res://shaders/mpm_ccl_propagate.glsl")
    if !mpm_ccl_prop_text.is_empty():
        var mpm_ccl_prop_source := RDShaderSource.new()
        mpm_ccl_prop_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_ccl_prop_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_ccl_prop_text)
        var mpm_ccl_prop_spirv := _rd.shader_compile_spirv_from_source(mpm_ccl_prop_source)
        var mpm_ccl_prop_error := mpm_ccl_prop_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_ccl_prop_error != "":
            push_error("MPM ccl_propagate shader compile error: %s" % mpm_ccl_prop_error)
        else:
            _mpm_ccl_propagate_shader_rid = _rd.shader_create_from_spirv(mpm_ccl_prop_spirv)
            if !_mpm_ccl_propagate_shader_rid.is_valid():
                push_error("Failed to create MPM ccl_propagate shader.")
            else:
                _mpm_ccl_propagate_pipeline_rid = _rd.compute_pipeline_create(_mpm_ccl_propagate_shader_rid)
                if !_mpm_ccl_propagate_pipeline_rid.is_valid():
                    push_error("Failed to create MPM ccl_propagate pipeline.")

    _mpm_ccl_write_shader_rid = RID()
    _mpm_ccl_write_pipeline_rid = RID()
    var mpm_ccl_write_text := FileAccess.get_file_as_string("res://shaders/mpm_ccl_write_meta.glsl")
    if !mpm_ccl_write_text.is_empty():
        var mpm_ccl_write_source := RDShaderSource.new()
        mpm_ccl_write_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_ccl_write_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_ccl_write_text)
        var mpm_ccl_write_spirv := _rd.shader_compile_spirv_from_source(mpm_ccl_write_source)
        var mpm_ccl_write_error := mpm_ccl_write_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_ccl_write_error != "":
            push_error("MPM ccl_write_meta shader compile error: %s" % mpm_ccl_write_error)
        else:
            _mpm_ccl_write_shader_rid = _rd.shader_create_from_spirv(mpm_ccl_write_spirv)
            if !_mpm_ccl_write_shader_rid.is_valid():
                push_error("Failed to create MPM ccl_write_meta shader.")
            else:
                _mpm_ccl_write_pipeline_rid = _rd.compute_pipeline_create(_mpm_ccl_write_shader_rid)
                if !_mpm_ccl_write_pipeline_rid.is_valid():
                    push_error("Failed to create MPM ccl_write_meta pipeline.")

    _mpm_island_accum0_shader_rid = RID()
    _mpm_island_accum0_pipeline_rid = RID()
    var mpm_island_accum0_text := FileAccess.get_file_as_string("res://shaders/mpm_island_accum0.glsl")
    if !mpm_island_accum0_text.is_empty():
        var mpm_island_accum0_source := RDShaderSource.new()
        mpm_island_accum0_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_island_accum0_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_island_accum0_text)
        var mpm_island_accum0_spirv := _rd.shader_compile_spirv_from_source(mpm_island_accum0_source)
        var mpm_island_accum0_error := mpm_island_accum0_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_island_accum0_error != "":
            push_error("MPM island_accum0 shader compile error: %s" % mpm_island_accum0_error)
        else:
            _mpm_island_accum0_shader_rid = _rd.shader_create_from_spirv(mpm_island_accum0_spirv)
            if !_mpm_island_accum0_shader_rid.is_valid():
                push_error("Failed to create MPM island_accum0 shader.")
            else:
                _mpm_island_accum0_pipeline_rid = _rd.compute_pipeline_create(_mpm_island_accum0_shader_rid)
                if !_mpm_island_accum0_pipeline_rid.is_valid():
                    push_error("Failed to create MPM island_accum0 pipeline.")

    _mpm_island_finalize_shader_rid = RID()
    _mpm_island_finalize_pipeline_rid = RID()
    var mpm_island_finalize_text := FileAccess.get_file_as_string("res://shaders/mpm_island_finalize.glsl")
    if !mpm_island_finalize_text.is_empty():
        var mpm_island_finalize_source := RDShaderSource.new()
        mpm_island_finalize_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_island_finalize_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_island_finalize_text)
        var mpm_island_finalize_spirv := _rd.shader_compile_spirv_from_source(mpm_island_finalize_source)
        var mpm_island_finalize_error := mpm_island_finalize_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_island_finalize_error != "":
            push_error("MPM island_finalize shader compile error: %s" % mpm_island_finalize_error)
        else:
            _mpm_island_finalize_shader_rid = _rd.shader_create_from_spirv(mpm_island_finalize_spirv)
            if !_mpm_island_finalize_shader_rid.is_valid():
                push_error("Failed to create MPM island_finalize shader.")
            else:
                _mpm_island_finalize_pipeline_rid = _rd.compute_pipeline_create(_mpm_island_finalize_shader_rid)
                if !_mpm_island_finalize_pipeline_rid.is_valid():
                    push_error("Failed to create MPM island_finalize pipeline.")

    _mpm_island_accum1_shader_rid = RID()
    _mpm_island_accum1_pipeline_rid = RID()
    var mpm_island_accum1_text := FileAccess.get_file_as_string("res://shaders/mpm_island_accum1.glsl")
    if !mpm_island_accum1_text.is_empty():
        var mpm_island_accum1_source := RDShaderSource.new()
        mpm_island_accum1_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_island_accum1_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_island_accum1_text)
        var mpm_island_accum1_spirv := _rd.shader_compile_spirv_from_source(mpm_island_accum1_source)
        var mpm_island_accum1_error := mpm_island_accum1_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_island_accum1_error != "":
            push_error("MPM island_accum1 shader compile error: %s" % mpm_island_accum1_error)
        else:
            _mpm_island_accum1_shader_rid = _rd.shader_create_from_spirv(mpm_island_accum1_spirv)
            if !_mpm_island_accum1_shader_rid.is_valid():
                push_error("Failed to create MPM island_accum1 shader.")
            else:
                _mpm_island_accum1_pipeline_rid = _rd.compute_pipeline_create(_mpm_island_accum1_shader_rid)
                if !_mpm_island_accum1_pipeline_rid.is_valid():
                    push_error("Failed to create MPM island_accum1 pipeline.")

    _mpm_island_apply_shader_rid = RID()
    _mpm_island_apply_pipeline_rid = RID()
    var mpm_island_apply_text := FileAccess.get_file_as_string("res://shaders/mpm_island_apply.glsl")
    if !mpm_island_apply_text.is_empty():
        var mpm_island_apply_source := RDShaderSource.new()
        mpm_island_apply_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_island_apply_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_island_apply_text)
        var mpm_island_apply_spirv := _rd.shader_compile_spirv_from_source(mpm_island_apply_source)
        var mpm_island_apply_error := mpm_island_apply_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_island_apply_error != "":
            push_error("MPM island_apply shader compile error: %s" % mpm_island_apply_error)
        else:
            _mpm_island_apply_shader_rid = _rd.shader_create_from_spirv(mpm_island_apply_spirv)
            if !_mpm_island_apply_shader_rid.is_valid():
                push_error("Failed to create MPM island_apply shader.")
            else:
                _mpm_island_apply_pipeline_rid = _rd.compute_pipeline_create(_mpm_island_apply_shader_rid)
                if !_mpm_island_apply_pipeline_rid.is_valid():
                    push_error("Failed to create MPM island_apply pipeline.")

    _mpm_stats_init_shader_rid = RID()
    _mpm_stats_init_pipeline_rid = RID()
    var mpm_stats_init_text := FileAccess.get_file_as_string("res://shaders/mpm_stats_init.glsl")
    if !mpm_stats_init_text.is_empty():
        var mpm_stats_init_source := RDShaderSource.new()
        mpm_stats_init_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_stats_init_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_stats_init_text)
        var mpm_stats_init_spirv := _rd.shader_compile_spirv_from_source(mpm_stats_init_source)
        var mpm_stats_init_error := mpm_stats_init_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_stats_init_error != "":
            push_error("MPM stats_init shader compile error: %s" % mpm_stats_init_error)
        else:
            _mpm_stats_init_shader_rid = _rd.shader_create_from_spirv(mpm_stats_init_spirv)
            if !_mpm_stats_init_shader_rid.is_valid():
                push_error("Failed to create MPM stats_init shader.")
            else:
                _mpm_stats_init_pipeline_rid = _rd.compute_pipeline_create(_mpm_stats_init_shader_rid)
                if !_mpm_stats_init_pipeline_rid.is_valid():
                    push_error("Failed to create MPM stats_init pipeline.")

    _mpm_stats_shader_rid = RID()
    _mpm_stats_pipeline_rid = RID()
    var mpm_stats_text := FileAccess.get_file_as_string("res://shaders/mpm_stats.glsl")
    if !mpm_stats_text.is_empty():
        var mpm_stats_source := RDShaderSource.new()
        mpm_stats_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
        mpm_stats_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, mpm_stats_text)
        var mpm_stats_spirv := _rd.shader_compile_spirv_from_source(mpm_stats_source)
        var mpm_stats_error := mpm_stats_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
        if mpm_stats_error != "":
            push_error("MPM stats shader compile error: %s" % mpm_stats_error)
        else:
            _mpm_stats_shader_rid = _rd.shader_create_from_spirv(mpm_stats_spirv)
            if !_mpm_stats_shader_rid.is_valid():
                push_error("Failed to create MPM stats shader.")
            else:
                _mpm_stats_pipeline_rid = _rd.compute_pipeline_create(_mpm_stats_shader_rid)
                if !_mpm_stats_pipeline_rid.is_valid():
                    push_error("Failed to create MPM stats pipeline.")

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

    # MPM stats buffer (small int SSBO used for autonomous regression tests).
    _mpm_stats_bytes = 1024
    _mpm_stats_rid = _rd.storage_buffer_create(_mpm_stats_bytes)
    if !_mpm_stats_rid.is_valid():
        push_error("Failed to create MPM stats buffer (mpm_stats disabled).")
        _mpm_stats_bytes = 0

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

    # MPM buffers (particles + Eulerian accumulation grid + static obstacles).
    _atlas_static_rid = _rd.storage_buffer_create(_atlas_bytes)
    if !_atlas_static_rid.is_valid():
        push_error("Failed to create static atlas buffer.")
        return
    _rd.buffer_clear(_atlas_static_rid, 0, _atlas_bytes)

    var max_p: int = maxi(1, mpm_max_particles)
    var particle_vec4_bytes: int = max_p * 16
    var particle_meta_bytes: int = max_p * 16
    var particle_mat3_bytes: int = max_p * 48
    _mpm_pos_mass_a_rid = _rd.storage_buffer_create(particle_vec4_bytes)
    _mpm_pos_mass_b_rid = _rd.storage_buffer_create(particle_vec4_bytes)
    _mpm_vel_vol_a_rid = _rd.storage_buffer_create(particle_vec4_bytes)
    _mpm_vel_vol_b_rid = _rd.storage_buffer_create(particle_vec4_bytes)
    _mpm_c_a_rid = _rd.storage_buffer_create(particle_mat3_bytes)
    _mpm_c_b_rid = _rd.storage_buffer_create(particle_mat3_bytes)
    _mpm_f_a_rid = _rd.storage_buffer_create(particle_mat3_bytes)
    _mpm_f_b_rid = _rd.storage_buffer_create(particle_mat3_bytes)
    _mpm_meta_rid = _rd.storage_buffer_create(particle_meta_bytes)
    _mpm_particle_count_rid = _rd.storage_buffer_create(4, PackedInt32Array([0]).to_byte_array())
    if !_mpm_pos_mass_a_rid.is_valid() or !_mpm_pos_mass_b_rid.is_valid() or !_mpm_vel_vol_a_rid.is_valid() or !_mpm_vel_vol_b_rid.is_valid() or !_mpm_c_a_rid.is_valid() or !_mpm_c_b_rid.is_valid() or !_mpm_f_a_rid.is_valid() or !_mpm_f_b_rid.is_valid() or !_mpm_meta_rid.is_valid() or !_mpm_particle_count_rid.is_valid():
        push_error("Failed to create one or more MPM particle buffers.")
        return
    _rd.buffer_clear(_mpm_pos_mass_a_rid, 0, particle_vec4_bytes)
    _rd.buffer_clear(_mpm_pos_mass_b_rid, 0, particle_vec4_bytes)
    _rd.buffer_clear(_mpm_vel_vol_a_rid, 0, particle_vec4_bytes)
    _rd.buffer_clear(_mpm_vel_vol_b_rid, 0, particle_vec4_bytes)
    _rd.buffer_clear(_mpm_c_a_rid, 0, particle_mat3_bytes)
    _rd.buffer_clear(_mpm_c_b_rid, 0, particle_mat3_bytes)
    _rd.buffer_clear(_mpm_f_a_rid, 0, particle_mat3_bytes)
    _rd.buffer_clear(_mpm_f_b_rid, 0, particle_mat3_bytes)
    _rd.buffer_clear(_mpm_meta_rid, 0, particle_meta_bytes)

    var total_cells := int(_atlas_bytes / 4)
    var grid_bytes := total_cells * 16
    _mpm_grid_accum_rid = _rd.storage_buffer_create(grid_bytes)
    _mpm_grid_vel_rid = _rd.storage_buffer_create(grid_bytes)
    if !_mpm_grid_accum_rid.is_valid() or !_mpm_grid_vel_rid.is_valid():
        push_error("Failed to create MPM grid buffers.")
        return
    _rd.buffer_clear(_mpm_grid_accum_rid, 0, grid_bytes)
    _rd.buffer_clear(_mpm_grid_vel_rid, 0, grid_bytes)

    # MPM rigid/island/fracture buffers.
    var rigid_map_bytes := total_cells * 4
    _mpm_rigid_map_rid = _rd.storage_buffer_create(rigid_map_bytes)
    if !_mpm_rigid_map_rid.is_valid():
        push_error("Failed to create MPM rigid map buffer.")
        return
    _rd.buffer_clear(_mpm_rigid_map_rid, 0, rigid_map_bytes)

    var cell_pos_bytes := total_cells * 16
    _mpm_cell_pos_rid = _rd.storage_buffer_create(cell_pos_bytes)
    if !_mpm_cell_pos_rid.is_valid():
        push_error("Failed to create MPM cell position buffer.")
        return
    _rd.buffer_clear(_mpm_cell_pos_rid, 0, cell_pos_bytes)

    var labels_bytes := max_p * 4
    _mpm_labels_a_rid = _rd.storage_buffer_create(labels_bytes)
    _mpm_labels_b_rid = _rd.storage_buffer_create(labels_bytes)
    if !_mpm_labels_a_rid.is_valid() or !_mpm_labels_b_rid.is_valid():
        push_error("Failed to create one or more MPM label buffers.")
        return
    _rd.buffer_clear(_mpm_labels_a_rid, 0, labels_bytes)
    _rd.buffer_clear(_mpm_labels_b_rid, 0, labels_bytes)

    var island_count := max_p + 1
    # island_finalize.glsl dispatches in 256-wide groups without a bounds check.
    # Pad the buffers so "extra" invocations stay in-bounds.
    var island_groups := int(ceil(float(island_count) / 256.0))
    var island_bytes := island_groups * 256 * 16
    _mpm_island_mass_mom_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_mass_com_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_com_mass_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_vel_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_L_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_I0_rid = _rd.storage_buffer_create(island_bytes)
    _mpm_island_I1_rid = _rd.storage_buffer_create(island_bytes)
    if !_mpm_island_mass_mom_rid.is_valid() or !_mpm_island_mass_com_rid.is_valid() or !_mpm_island_com_mass_rid.is_valid() or !_mpm_island_vel_rid.is_valid() or !_mpm_island_L_rid.is_valid() or !_mpm_island_I0_rid.is_valid() or !_mpm_island_I1_rid.is_valid():
        push_error("Failed to create one or more MPM island buffers.")
        return
    _rd.buffer_clear(_mpm_island_mass_mom_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_mass_com_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_com_mass_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_vel_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_L_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_I0_rid, 0, island_bytes)
    _rd.buffer_clear(_mpm_island_I1_rid, 0, island_bytes)

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
    var cell_pos_uniform := RDUniform.new()
    cell_pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    cell_pos_uniform.binding = 10
    cell_pos_uniform.add_id(_mpm_cell_pos_rid)

    var light_uniform_a := RDUniform.new()
    light_uniform_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    light_uniform_a.binding = 6
    light_uniform_a.add_id(_light_a_rid)

    var light_uniform_b := RDUniform.new()
    light_uniform_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    light_uniform_b.binding = 6
    light_uniform_b.add_id(_light_b_rid)

    _uniform_set_a_light_a_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_a, occupancy_uniform, metrics_uniform, light_uniform_a, preview_uniform, cursor_uniform, preview_occ_uniform, cell_pos_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_a_light_a_rid.is_valid():
        push_error("Failed to create uniform set A (light A).")
        return
    _uniform_set_a_light_b_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_a, occupancy_uniform, metrics_uniform, light_uniform_b, preview_uniform, cursor_uniform, preview_occ_uniform, cell_pos_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_a_light_b_rid.is_valid():
        push_error("Failed to create uniform set A (light B).")
        return
    _uniform_set_b_light_a_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_b, occupancy_uniform, metrics_uniform, light_uniform_a, preview_uniform, cursor_uniform, preview_occ_uniform, cell_pos_uniform],
        _shader_rid,
        0
    )
    if !_uniform_set_b_light_a_rid.is_valid():
        push_error("Failed to create uniform set B (light A).")
        return
    _uniform_set_b_light_b_rid = _rd.uniform_set_create(
        [img_uniform, ubo_uniform, indirection_uniform, atlas_uniform_b, occupancy_uniform, metrics_uniform, light_uniform_b, preview_uniform, cursor_uniform, preview_occ_uniform, cell_pos_uniform],
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

    # MPM uniform sets.
    if _mpm_copy_static_shader_rid.is_valid():
        var mpm_copy_ubo := RDUniform.new()
        mpm_copy_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_copy_ubo.binding = 0
        mpm_copy_ubo.add_id(_ubo_rid)

        var mpm_static_uniform := RDUniform.new()
        mpm_static_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_static_uniform.binding = 1
        mpm_static_uniform.add_id(_atlas_static_rid)

        var mpm_copy_out_a := RDUniform.new()
        mpm_copy_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_copy_out_a.binding = 2
        mpm_copy_out_a.add_id(_atlas_a_rid)
        _mpm_copy_uniform_set_a = _rd.uniform_set_create([mpm_copy_ubo, mpm_static_uniform, mpm_copy_out_a], _mpm_copy_static_shader_rid, 0)

        var mpm_copy_out_b := RDUniform.new()
        mpm_copy_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_copy_out_b.binding = 2
        mpm_copy_out_b.add_id(_atlas_b_rid)
        _mpm_copy_uniform_set_b = _rd.uniform_set_create([mpm_copy_ubo, mpm_static_uniform, mpm_copy_out_b], _mpm_copy_static_shader_rid, 0)

    if _mpm_init_particles_shader_rid.is_valid():
        var mpm_init_meta := RDUniform.new()
        mpm_init_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_meta.binding = 0
        mpm_init_meta.add_id(_mpm_meta_rid)
        var mpm_init_count := RDUniform.new()
        mpm_init_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_count.binding = 1
        mpm_init_count.add_id(_mpm_particle_count_rid)
        var mpm_init_c_a := RDUniform.new()
        mpm_init_c_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_c_a.binding = 2
        mpm_init_c_a.add_id(_mpm_c_a_rid)
        var mpm_init_f_a := RDUniform.new()
        mpm_init_f_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_f_a.binding = 3
        mpm_init_f_a.add_id(_mpm_f_a_rid)
        var mpm_init_c_b := RDUniform.new()
        mpm_init_c_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_c_b.binding = 4
        mpm_init_c_b.add_id(_mpm_c_b_rid)
        var mpm_init_f_b := RDUniform.new()
        mpm_init_f_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_init_f_b.binding = 5
        mpm_init_f_b.add_id(_mpm_f_b_rid)
        _mpm_init_uniform_set = _rd.uniform_set_create(
            [mpm_init_meta, mpm_init_count, mpm_init_c_a, mpm_init_f_a, mpm_init_c_b, mpm_init_f_b],
            _mpm_init_particles_shader_rid,
            0
        )

    if _mpm_p2g_shader_rid.is_valid():
        var mpm_ubo := RDUniform.new()
        mpm_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_ubo.binding = 0
        mpm_ubo.add_id(_ubo_rid)
        var mpm_indirection := RDUniform.new()
        mpm_indirection.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_indirection.binding = 1
        mpm_indirection.add_id(_indirection_rid)
        var mpm_meta := RDUniform.new()
        mpm_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_meta.binding = 6
        mpm_meta.add_id(_mpm_meta_rid)
        var mpm_count := RDUniform.new()
        mpm_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_count.binding = 7
        mpm_count.add_id(_mpm_particle_count_rid)
        var mpm_grid_accum := RDUniform.new()
        mpm_grid_accum.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_grid_accum.binding = 8
        mpm_grid_accum.add_id(_mpm_grid_accum_rid)

        var mpm_pos_a := RDUniform.new()
        mpm_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_a.binding = 2
        mpm_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_vel_a := RDUniform.new()
        mpm_vel_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_a.binding = 3
        mpm_vel_a.add_id(_mpm_vel_vol_a_rid)
        var mpm_c_a := RDUniform.new()
        mpm_c_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_a.binding = 4
        mpm_c_a.add_id(_mpm_c_a_rid)
        var mpm_f_a := RDUniform.new()
        mpm_f_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_a.binding = 5
        mpm_f_a.add_id(_mpm_f_a_rid)
        _mpm_p2g_uniform_set_a = _rd.uniform_set_create([mpm_ubo, mpm_indirection, mpm_pos_a, mpm_vel_a, mpm_c_a, mpm_f_a, mpm_meta, mpm_count, mpm_grid_accum], _mpm_p2g_shader_rid, 0)

        var mpm_pos_b := RDUniform.new()
        mpm_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_b.binding = 2
        mpm_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_vel_b := RDUniform.new()
        mpm_vel_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_b.binding = 3
        mpm_vel_b.add_id(_mpm_vel_vol_b_rid)
        var mpm_c_b := RDUniform.new()
        mpm_c_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_b.binding = 4
        mpm_c_b.add_id(_mpm_c_b_rid)
        var mpm_f_b := RDUniform.new()
        mpm_f_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_b.binding = 5
        mpm_f_b.add_id(_mpm_f_b_rid)
        _mpm_p2g_uniform_set_b = _rd.uniform_set_create([mpm_ubo, mpm_indirection, mpm_pos_b, mpm_vel_b, mpm_c_b, mpm_f_b, mpm_meta, mpm_count, mpm_grid_accum], _mpm_p2g_shader_rid, 0)

    if _mpm_grid_update_shader_rid.is_valid():
        var mpm_grid_ubo := RDUniform.new()
        mpm_grid_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_grid_ubo.binding = 0
        mpm_grid_ubo.add_id(_ubo_rid)
        var mpm_grid_static := RDUniform.new()
        mpm_grid_static.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_grid_static.binding = 1
        mpm_grid_static.add_id(_atlas_static_rid)
        var mpm_grid_acc := RDUniform.new()
        mpm_grid_acc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_grid_acc.binding = 2
        mpm_grid_acc.add_id(_mpm_grid_accum_rid)
        var mpm_grid_vel := RDUniform.new()
        mpm_grid_vel.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_grid_vel.binding = 3
        mpm_grid_vel.add_id(_mpm_grid_vel_rid)
        _mpm_grid_uniform_set = _rd.uniform_set_create([mpm_grid_ubo, mpm_grid_static, mpm_grid_acc, mpm_grid_vel], _mpm_grid_update_shader_rid, 0)

    if _mpm_g2p_advect_shader_rid.is_valid():
        var mpm_g2p_ubo := RDUniform.new()
        mpm_g2p_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_g2p_ubo.binding = 0
        mpm_g2p_ubo.add_id(_ubo_rid)
        var mpm_g2p_indirection := RDUniform.new()
        mpm_g2p_indirection.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_g2p_indirection.binding = 1
        mpm_g2p_indirection.add_id(_indirection_rid)
        var mpm_g2p_meta := RDUniform.new()
        mpm_g2p_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_g2p_meta.binding = 10
        mpm_g2p_meta.add_id(_mpm_meta_rid)
        var mpm_g2p_count := RDUniform.new()
        mpm_g2p_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_g2p_count.binding = 11
        mpm_g2p_count.add_id(_mpm_particle_count_rid)
        var mpm_g2p_grid_vel := RDUniform.new()
        mpm_g2p_grid_vel.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_g2p_grid_vel.binding = 12
        mpm_g2p_grid_vel.add_id(_mpm_grid_vel_rid)
        var mpm_g2p_static := RDUniform.new()
        mpm_g2p_static.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_g2p_static.binding = 13
        mpm_g2p_static.add_id(_atlas_static_rid)

        var mpm_pos_in_a := RDUniform.new()
        mpm_pos_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_in_a.binding = 2
        mpm_pos_in_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_vel_in_a := RDUniform.new()
        mpm_vel_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_in_a.binding = 3
        mpm_vel_in_a.add_id(_mpm_vel_vol_a_rid)
        var mpm_c_in_a := RDUniform.new()
        mpm_c_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_in_a.binding = 4
        mpm_c_in_a.add_id(_mpm_c_a_rid)
        var mpm_f_in_a := RDUniform.new()
        mpm_f_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_in_a.binding = 5
        mpm_f_in_a.add_id(_mpm_f_a_rid)
        var mpm_pos_out_b := RDUniform.new()
        mpm_pos_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_out_b.binding = 6
        mpm_pos_out_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_vel_out_b := RDUniform.new()
        mpm_vel_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_out_b.binding = 7
        mpm_vel_out_b.add_id(_mpm_vel_vol_b_rid)
        var mpm_c_out_b := RDUniform.new()
        mpm_c_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_out_b.binding = 8
        mpm_c_out_b.add_id(_mpm_c_b_rid)
        var mpm_f_out_b := RDUniform.new()
        mpm_f_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_out_b.binding = 9
        mpm_f_out_b.add_id(_mpm_f_b_rid)
        _mpm_g2p_uniform_set_ab = _rd.uniform_set_create(
            [mpm_g2p_ubo, mpm_g2p_indirection, mpm_pos_in_a, mpm_vel_in_a, mpm_c_in_a, mpm_f_in_a, mpm_pos_out_b, mpm_vel_out_b, mpm_c_out_b, mpm_f_out_b, mpm_g2p_meta, mpm_g2p_count, mpm_g2p_grid_vel, mpm_g2p_static],
            _mpm_g2p_advect_shader_rid,
            0
        )

        var mpm_pos_in_b := RDUniform.new()
        mpm_pos_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_in_b.binding = 2
        mpm_pos_in_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_vel_in_b := RDUniform.new()
        mpm_vel_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_in_b.binding = 3
        mpm_vel_in_b.add_id(_mpm_vel_vol_b_rid)
        var mpm_c_in_b := RDUniform.new()
        mpm_c_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_in_b.binding = 4
        mpm_c_in_b.add_id(_mpm_c_b_rid)
        var mpm_f_in_b := RDUniform.new()
        mpm_f_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_in_b.binding = 5
        mpm_f_in_b.add_id(_mpm_f_b_rid)
        var mpm_pos_out_a := RDUniform.new()
        mpm_pos_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pos_out_a.binding = 6
        mpm_pos_out_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_vel_out_a := RDUniform.new()
        mpm_vel_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_vel_out_a.binding = 7
        mpm_vel_out_a.add_id(_mpm_vel_vol_a_rid)
        var mpm_c_out_a := RDUniform.new()
        mpm_c_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_c_out_a.binding = 8
        mpm_c_out_a.add_id(_mpm_c_a_rid)
        var mpm_f_out_a := RDUniform.new()
        mpm_f_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_f_out_a.binding = 9
        mpm_f_out_a.add_id(_mpm_f_a_rid)
        _mpm_g2p_uniform_set_ba = _rd.uniform_set_create(
            [mpm_g2p_ubo, mpm_g2p_indirection, mpm_pos_in_b, mpm_vel_in_b, mpm_c_in_b, mpm_f_in_b, mpm_pos_out_a, mpm_vel_out_a, mpm_c_out_a, mpm_f_out_a, mpm_g2p_meta, mpm_g2p_count, mpm_g2p_grid_vel, mpm_g2p_static],
            _mpm_g2p_advect_shader_rid,
            0
        )

    if _mpm_grid_to_atlas_shader_rid.is_valid():
        var mpm_atlas_ubo := RDUniform.new()
        mpm_atlas_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_atlas_ubo.binding = 0
        mpm_atlas_ubo.add_id(_ubo_rid)
        var mpm_atlas_static := RDUniform.new()
        mpm_atlas_static.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_atlas_static.binding = 1
        mpm_atlas_static.add_id(_atlas_static_rid)
        var mpm_atlas_grid := RDUniform.new()
        mpm_atlas_grid.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_atlas_grid.binding = 2
        mpm_atlas_grid.add_id(_mpm_grid_vel_rid)

        var mpm_atlas_out_a := RDUniform.new()
        mpm_atlas_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_atlas_out_a.binding = 3
        mpm_atlas_out_a.add_id(_atlas_a_rid)
        _mpm_grid_to_atlas_uniform_set_a = _rd.uniform_set_create(
            [mpm_atlas_ubo, mpm_atlas_static, mpm_atlas_grid, mpm_atlas_out_a],
            _mpm_grid_to_atlas_shader_rid,
            0
        )

        var mpm_atlas_out_b := RDUniform.new()
        mpm_atlas_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_atlas_out_b.binding = 3
        mpm_atlas_out_b.add_id(_atlas_b_rid)
        _mpm_grid_to_atlas_uniform_set_b = _rd.uniform_set_create(
            [mpm_atlas_ubo, mpm_atlas_static, mpm_atlas_grid, mpm_atlas_out_b],
            _mpm_grid_to_atlas_shader_rid,
            0
        )

    if _mpm_particles_to_atlas_shader_rid.is_valid():
        var mpm_pta_ubo := RDUniform.new()
        mpm_pta_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_pta_ubo.binding = 0
        mpm_pta_ubo.add_id(_ubo_rid)
        var mpm_pta_ind := RDUniform.new()
        mpm_pta_ind.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_ind.binding = 1
        mpm_pta_ind.add_id(_indirection_rid)
        var mpm_pta_meta := RDUniform.new()
        mpm_pta_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_meta.binding = 3
        mpm_pta_meta.add_id(_mpm_meta_rid)
        var mpm_pta_count := RDUniform.new()
        mpm_pta_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_count.binding = 4
        mpm_pta_count.add_id(_mpm_particle_count_rid)
        var mpm_pta_cell_pos := RDUniform.new()
        mpm_pta_cell_pos.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_cell_pos.binding = 6
        mpm_pta_cell_pos.add_id(_mpm_cell_pos_rid)

        var mpm_pta_pos_a := RDUniform.new()
        mpm_pta_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_pos_a.binding = 2
        mpm_pta_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_pta_out_a := RDUniform.new()
        mpm_pta_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_out_a.binding = 5
        mpm_pta_out_a.add_id(_atlas_a_rid)
        _mpm_particles_to_atlas_uniform_set_a = _rd.uniform_set_create(
            [mpm_pta_ubo, mpm_pta_ind, mpm_pta_pos_a, mpm_pta_meta, mpm_pta_count, mpm_pta_out_a, mpm_pta_cell_pos],
            _mpm_particles_to_atlas_shader_rid,
            0
        )

        var mpm_pta_pos_b := RDUniform.new()
        mpm_pta_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_pos_b.binding = 2
        mpm_pta_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_pta_out_b := RDUniform.new()
        mpm_pta_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_pta_out_b.binding = 5
        mpm_pta_out_b.add_id(_atlas_b_rid)
        _mpm_particles_to_atlas_uniform_set_b = _rd.uniform_set_create(
            [mpm_pta_ubo, mpm_pta_ind, mpm_pta_pos_b, mpm_pta_meta, mpm_pta_count, mpm_pta_out_b, mpm_pta_cell_pos],
            _mpm_particles_to_atlas_shader_rid,
            0
        )

    if _mpm_build_rigid_map_shader_rid.is_valid():
        var mpm_rm_ubo := RDUniform.new()
        mpm_rm_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_rm_ubo.binding = 0
        mpm_rm_ubo.add_id(_ubo_rid)
        var mpm_rm_ind := RDUniform.new()
        mpm_rm_ind.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_ind.binding = 1
        mpm_rm_ind.add_id(_indirection_rid)
        var mpm_rm_meta := RDUniform.new()
        mpm_rm_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_meta.binding = 3
        mpm_rm_meta.add_id(_mpm_meta_rid)
        var mpm_rm_count := RDUniform.new()
        mpm_rm_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_count.binding = 4
        mpm_rm_count.add_id(_mpm_particle_count_rid)
        var mpm_rm_out := RDUniform.new()
        mpm_rm_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_out.binding = 5
        mpm_rm_out.add_id(_mpm_rigid_map_rid)

        var mpm_rm_pos_a := RDUniform.new()
        mpm_rm_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_pos_a.binding = 2
        mpm_rm_pos_a.add_id(_mpm_pos_mass_a_rid)
        _mpm_rigid_map_set_a = _rd.uniform_set_create(
            [mpm_rm_ubo, mpm_rm_ind, mpm_rm_pos_a, mpm_rm_meta, mpm_rm_count, mpm_rm_out],
            _mpm_build_rigid_map_shader_rid,
            0
        )

        var mpm_rm_pos_b := RDUniform.new()
        mpm_rm_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_rm_pos_b.binding = 2
        mpm_rm_pos_b.add_id(_mpm_pos_mass_b_rid)
        _mpm_rigid_map_set_b = _rd.uniform_set_create(
            [mpm_rm_ubo, mpm_rm_ind, mpm_rm_pos_b, mpm_rm_meta, mpm_rm_count, mpm_rm_out],
            _mpm_build_rigid_map_shader_rid,
            0
        )

    if _mpm_update_bonds_shader_rid.is_valid():
        var mpm_bonds_ubo := RDUniform.new()
        mpm_bonds_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_bonds_ubo.binding = 0
        mpm_bonds_ubo.add_id(_ubo_rid)
        var mpm_bonds_ind := RDUniform.new()
        mpm_bonds_ind.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_ind.binding = 1
        mpm_bonds_ind.add_id(_indirection_rid)
        var mpm_bonds_meta := RDUniform.new()
        mpm_bonds_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_meta.binding = 4
        mpm_bonds_meta.add_id(_mpm_meta_rid)
        var mpm_bonds_count := RDUniform.new()
        mpm_bonds_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_count.binding = 5
        mpm_bonds_count.add_id(_mpm_particle_count_rid)
        var mpm_bonds_rigid := RDUniform.new()
        mpm_bonds_rigid.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_rigid.binding = 6
        mpm_bonds_rigid.add_id(_mpm_rigid_map_rid)

        var mpm_bonds_pos_a := RDUniform.new()
        mpm_bonds_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_pos_a.binding = 2
        mpm_bonds_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_bonds_f_a := RDUniform.new()
        mpm_bonds_f_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_f_a.binding = 3
        mpm_bonds_f_a.add_id(_mpm_f_a_rid)
        _mpm_update_bonds_set_a = _rd.uniform_set_create(
            [mpm_bonds_ubo, mpm_bonds_ind, mpm_bonds_pos_a, mpm_bonds_f_a, mpm_bonds_meta, mpm_bonds_count, mpm_bonds_rigid],
            _mpm_update_bonds_shader_rid,
            0
        )

        var mpm_bonds_pos_b := RDUniform.new()
        mpm_bonds_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_pos_b.binding = 2
        mpm_bonds_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_bonds_f_b := RDUniform.new()
        mpm_bonds_f_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_bonds_f_b.binding = 3
        mpm_bonds_f_b.add_id(_mpm_f_b_rid)
        _mpm_update_bonds_set_b = _rd.uniform_set_create(
            [mpm_bonds_ubo, mpm_bonds_ind, mpm_bonds_pos_b, mpm_bonds_f_b, mpm_bonds_meta, mpm_bonds_count, mpm_bonds_rigid],
            _mpm_update_bonds_shader_rid,
            0
        )

    if _mpm_ccl_init_shader_rid.is_valid():
        var mpm_ccl_meta := RDUniform.new()
        mpm_ccl_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ccl_meta.binding = 0
        mpm_ccl_meta.add_id(_mpm_meta_rid)
        var mpm_ccl_count := RDUniform.new()
        mpm_ccl_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ccl_count.binding = 1
        mpm_ccl_count.add_id(_mpm_particle_count_rid)

        var mpm_ccl_out_a := RDUniform.new()
        mpm_ccl_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ccl_out_a.binding = 2
        mpm_ccl_out_a.add_id(_mpm_labels_a_rid)
        _mpm_ccl_init_set_a = _rd.uniform_set_create(
            [mpm_ccl_meta, mpm_ccl_count, mpm_ccl_out_a],
            _mpm_ccl_init_shader_rid,
            0
        )

        var mpm_ccl_out_b := RDUniform.new()
        mpm_ccl_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ccl_out_b.binding = 2
        mpm_ccl_out_b.add_id(_mpm_labels_b_rid)
        _mpm_ccl_init_set_b = _rd.uniform_set_create(
            [mpm_ccl_meta, mpm_ccl_count, mpm_ccl_out_b],
            _mpm_ccl_init_shader_rid,
            0
        )

    if _mpm_ccl_propagate_shader_rid.is_valid():
        var mpm_prop_ubo := RDUniform.new()
        mpm_prop_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_prop_ubo.binding = 0
        mpm_prop_ubo.add_id(_ubo_rid)
        var mpm_prop_ind := RDUniform.new()
        mpm_prop_ind.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_ind.binding = 1
        mpm_prop_ind.add_id(_indirection_rid)
        var mpm_prop_meta := RDUniform.new()
        mpm_prop_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_meta.binding = 3
        mpm_prop_meta.add_id(_mpm_meta_rid)
        var mpm_prop_count := RDUniform.new()
        mpm_prop_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_count.binding = 4
        mpm_prop_count.add_id(_mpm_particle_count_rid)
        var mpm_prop_rigid := RDUniform.new()
        mpm_prop_rigid.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_rigid.binding = 5
        mpm_prop_rigid.add_id(_mpm_rigid_map_rid)

        var mpm_prop_pos_a := RDUniform.new()
        mpm_prop_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_pos_a.binding = 2
        mpm_prop_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_prop_pos_b := RDUniform.new()
        mpm_prop_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_pos_b.binding = 2
        mpm_prop_pos_b.add_id(_mpm_pos_mass_b_rid)

        var mpm_prop_lab_in_a := RDUniform.new()
        mpm_prop_lab_in_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_in_a.binding = 6
        mpm_prop_lab_in_a.add_id(_mpm_labels_a_rid)
        var mpm_prop_lab_out_b := RDUniform.new()
        mpm_prop_lab_out_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_out_b.binding = 7
        mpm_prop_lab_out_b.add_id(_mpm_labels_b_rid)
        _mpm_ccl_prop_set_a_ab = _rd.uniform_set_create(
            [mpm_prop_ubo, mpm_prop_ind, mpm_prop_pos_a, mpm_prop_meta, mpm_prop_count, mpm_prop_rigid, mpm_prop_lab_in_a, mpm_prop_lab_out_b],
            _mpm_ccl_propagate_shader_rid,
            0
        )
        var mpm_prop_lab_in_b := RDUniform.new()
        mpm_prop_lab_in_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_in_b.binding = 6
        mpm_prop_lab_in_b.add_id(_mpm_labels_b_rid)
        var mpm_prop_lab_out_a := RDUniform.new()
        mpm_prop_lab_out_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_out_a.binding = 7
        mpm_prop_lab_out_a.add_id(_mpm_labels_a_rid)
        _mpm_ccl_prop_set_a_ba = _rd.uniform_set_create(
            [mpm_prop_ubo, mpm_prop_ind, mpm_prop_pos_a, mpm_prop_meta, mpm_prop_count, mpm_prop_rigid, mpm_prop_lab_in_b, mpm_prop_lab_out_a],
            _mpm_ccl_propagate_shader_rid,
            0
        )

        var mpm_prop_lab_in_a2 := RDUniform.new()
        mpm_prop_lab_in_a2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_in_a2.binding = 6
        mpm_prop_lab_in_a2.add_id(_mpm_labels_a_rid)
        var mpm_prop_lab_out_b2 := RDUniform.new()
        mpm_prop_lab_out_b2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_out_b2.binding = 7
        mpm_prop_lab_out_b2.add_id(_mpm_labels_b_rid)
        _mpm_ccl_prop_set_b_ab = _rd.uniform_set_create(
            [mpm_prop_ubo, mpm_prop_ind, mpm_prop_pos_b, mpm_prop_meta, mpm_prop_count, mpm_prop_rigid, mpm_prop_lab_in_a2, mpm_prop_lab_out_b2],
            _mpm_ccl_propagate_shader_rid,
            0
        )
        var mpm_prop_lab_in_b2 := RDUniform.new()
        mpm_prop_lab_in_b2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_in_b2.binding = 6
        mpm_prop_lab_in_b2.add_id(_mpm_labels_b_rid)
        var mpm_prop_lab_out_a2 := RDUniform.new()
        mpm_prop_lab_out_a2.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_prop_lab_out_a2.binding = 7
        mpm_prop_lab_out_a2.add_id(_mpm_labels_a_rid)
        _mpm_ccl_prop_set_b_ba = _rd.uniform_set_create(
            [mpm_prop_ubo, mpm_prop_ind, mpm_prop_pos_b, mpm_prop_meta, mpm_prop_count, mpm_prop_rigid, mpm_prop_lab_in_b2, mpm_prop_lab_out_a2],
            _mpm_ccl_propagate_shader_rid,
            0
        )

    if _mpm_ccl_write_shader_rid.is_valid():
        var mpm_write_meta := RDUniform.new()
        mpm_write_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_write_meta.binding = 0
        mpm_write_meta.add_id(_mpm_meta_rid)
        var mpm_write_count := RDUniform.new()
        mpm_write_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_write_count.binding = 1
        mpm_write_count.add_id(_mpm_particle_count_rid)

        var mpm_write_lab_a := RDUniform.new()
        mpm_write_lab_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_write_lab_a.binding = 2
        mpm_write_lab_a.add_id(_mpm_labels_a_rid)
        _mpm_ccl_write_set_a = _rd.uniform_set_create(
            [mpm_write_meta, mpm_write_count, mpm_write_lab_a],
            _mpm_ccl_write_shader_rid,
            0
        )

        var mpm_write_lab_b := RDUniform.new()
        mpm_write_lab_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_write_lab_b.binding = 2
        mpm_write_lab_b.add_id(_mpm_labels_b_rid)
        _mpm_ccl_write_set_b = _rd.uniform_set_create(
            [mpm_write_meta, mpm_write_count, mpm_write_lab_b],
            _mpm_ccl_write_shader_rid,
            0
        )

    if _mpm_island_accum0_shader_rid.is_valid():
        var mpm_ia0_meta := RDUniform.new()
        mpm_ia0_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_meta.binding = 2
        mpm_ia0_meta.add_id(_mpm_meta_rid)
        var mpm_ia0_count := RDUniform.new()
        mpm_ia0_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_count.binding = 3
        mpm_ia0_count.add_id(_mpm_particle_count_rid)
        var mpm_ia0_mm := RDUniform.new()
        mpm_ia0_mm.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_mm.binding = 4
        mpm_ia0_mm.add_id(_mpm_island_mass_mom_rid)
        var mpm_ia0_mc := RDUniform.new()
        mpm_ia0_mc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_mc.binding = 5
        mpm_ia0_mc.add_id(_mpm_island_mass_com_rid)

        var mpm_ia0_pos_a := RDUniform.new()
        mpm_ia0_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_pos_a.binding = 0
        mpm_ia0_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_ia0_vel_a := RDUniform.new()
        mpm_ia0_vel_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_vel_a.binding = 1
        mpm_ia0_vel_a.add_id(_mpm_vel_vol_a_rid)
        _mpm_island_accum0_set_a = _rd.uniform_set_create(
            [mpm_ia0_pos_a, mpm_ia0_vel_a, mpm_ia0_meta, mpm_ia0_count, mpm_ia0_mm, mpm_ia0_mc],
            _mpm_island_accum0_shader_rid,
            0
        )

        var mpm_ia0_pos_b := RDUniform.new()
        mpm_ia0_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_pos_b.binding = 0
        mpm_ia0_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_ia0_vel_b := RDUniform.new()
        mpm_ia0_vel_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia0_vel_b.binding = 1
        mpm_ia0_vel_b.add_id(_mpm_vel_vol_b_rid)
        _mpm_island_accum0_set_b = _rd.uniform_set_create(
            [mpm_ia0_pos_b, mpm_ia0_vel_b, mpm_ia0_meta, mpm_ia0_count, mpm_ia0_mm, mpm_ia0_mc],
            _mpm_island_accum0_shader_rid,
            0
        )

    if _mpm_island_finalize_shader_rid.is_valid():
        var mpm_if_mm := RDUniform.new()
        mpm_if_mm.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_if_mm.binding = 0
        mpm_if_mm.add_id(_mpm_island_mass_mom_rid)
        var mpm_if_mc := RDUniform.new()
        mpm_if_mc.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_if_mc.binding = 1
        mpm_if_mc.add_id(_mpm_island_mass_com_rid)
        var mpm_if_cm := RDUniform.new()
        mpm_if_cm.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_if_cm.binding = 2
        mpm_if_cm.add_id(_mpm_island_com_mass_rid)
        var mpm_if_v := RDUniform.new()
        mpm_if_v.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_if_v.binding = 3
        mpm_if_v.add_id(_mpm_island_vel_rid)
        _mpm_island_finalize_set = _rd.uniform_set_create(
            [mpm_if_mm, mpm_if_mc, mpm_if_cm, mpm_if_v],
            _mpm_island_finalize_shader_rid,
            0
        )

    if _mpm_island_accum1_shader_rid.is_valid():
        var mpm_ia1_meta := RDUniform.new()
        mpm_ia1_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_meta.binding = 2
        mpm_ia1_meta.add_id(_mpm_meta_rid)
        var mpm_ia1_count := RDUniform.new()
        mpm_ia1_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_count.binding = 3
        mpm_ia1_count.add_id(_mpm_particle_count_rid)
        var mpm_ia1_cm := RDUniform.new()
        mpm_ia1_cm.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_cm.binding = 4
        mpm_ia1_cm.add_id(_mpm_island_com_mass_rid)
        var mpm_ia1_v := RDUniform.new()
        mpm_ia1_v.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_v.binding = 5
        mpm_ia1_v.add_id(_mpm_island_vel_rid)
        var mpm_ia1_L := RDUniform.new()
        mpm_ia1_L.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_L.binding = 6
        mpm_ia1_L.add_id(_mpm_island_L_rid)
        var mpm_ia1_I0 := RDUniform.new()
        mpm_ia1_I0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_I0.binding = 7
        mpm_ia1_I0.add_id(_mpm_island_I0_rid)
        var mpm_ia1_I1 := RDUniform.new()
        mpm_ia1_I1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_I1.binding = 8
        mpm_ia1_I1.add_id(_mpm_island_I1_rid)

        var mpm_ia1_pos_a := RDUniform.new()
        mpm_ia1_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_pos_a.binding = 0
        mpm_ia1_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_ia1_vel_a := RDUniform.new()
        mpm_ia1_vel_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_vel_a.binding = 1
        mpm_ia1_vel_a.add_id(_mpm_vel_vol_a_rid)
        _mpm_island_accum1_set_a = _rd.uniform_set_create(
            [mpm_ia1_pos_a, mpm_ia1_vel_a, mpm_ia1_meta, mpm_ia1_count, mpm_ia1_cm, mpm_ia1_v, mpm_ia1_L, mpm_ia1_I0, mpm_ia1_I1],
            _mpm_island_accum1_shader_rid,
            0
        )

        var mpm_ia1_pos_b := RDUniform.new()
        mpm_ia1_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_pos_b.binding = 0
        mpm_ia1_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_ia1_vel_b := RDUniform.new()
        mpm_ia1_vel_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_ia1_vel_b.binding = 1
        mpm_ia1_vel_b.add_id(_mpm_vel_vol_b_rid)
        _mpm_island_accum1_set_b = _rd.uniform_set_create(
            [mpm_ia1_pos_b, mpm_ia1_vel_b, mpm_ia1_meta, mpm_ia1_count, mpm_ia1_cm, mpm_ia1_v, mpm_ia1_L, mpm_ia1_I0, mpm_ia1_I1],
            _mpm_island_accum1_shader_rid,
            0
        )

    if _mpm_island_apply_shader_rid.is_valid():
        var mpm_iap_meta := RDUniform.new()
        mpm_iap_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_meta.binding = 3
        mpm_iap_meta.add_id(_mpm_meta_rid)
        var mpm_iap_count := RDUniform.new()
        mpm_iap_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_count.binding = 4
        mpm_iap_count.add_id(_mpm_particle_count_rid)
        var mpm_iap_cm := RDUniform.new()
        mpm_iap_cm.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_cm.binding = 5
        mpm_iap_cm.add_id(_mpm_island_com_mass_rid)
        var mpm_iap_v := RDUniform.new()
        mpm_iap_v.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_v.binding = 6
        mpm_iap_v.add_id(_mpm_island_vel_rid)
        var mpm_iap_L := RDUniform.new()
        mpm_iap_L.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_L.binding = 7
        mpm_iap_L.add_id(_mpm_island_L_rid)
        var mpm_iap_I0 := RDUniform.new()
        mpm_iap_I0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_I0.binding = 8
        mpm_iap_I0.add_id(_mpm_island_I0_rid)
        var mpm_iap_I1 := RDUniform.new()
        mpm_iap_I1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_I1.binding = 9
        mpm_iap_I1.add_id(_mpm_island_I1_rid)

        var mpm_iap_vel_a := RDUniform.new()
        mpm_iap_vel_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_vel_a.binding = 0
        mpm_iap_vel_a.add_id(_mpm_vel_vol_a_rid)
        var mpm_iap_c_a := RDUniform.new()
        mpm_iap_c_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_c_a.binding = 1
        mpm_iap_c_a.add_id(_mpm_c_a_rid)
        var mpm_iap_pos_a := RDUniform.new()
        mpm_iap_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_pos_a.binding = 2
        mpm_iap_pos_a.add_id(_mpm_pos_mass_a_rid)
        _mpm_island_apply_set_a = _rd.uniform_set_create(
            [mpm_iap_vel_a, mpm_iap_c_a, mpm_iap_pos_a, mpm_iap_meta, mpm_iap_count, mpm_iap_cm, mpm_iap_v, mpm_iap_L, mpm_iap_I0, mpm_iap_I1],
            _mpm_island_apply_shader_rid,
            0
        )

        var mpm_iap_vel_b := RDUniform.new()
        mpm_iap_vel_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_vel_b.binding = 0
        mpm_iap_vel_b.add_id(_mpm_vel_vol_b_rid)
        var mpm_iap_c_b := RDUniform.new()
        mpm_iap_c_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_c_b.binding = 1
        mpm_iap_c_b.add_id(_mpm_c_b_rid)
        var mpm_iap_pos_b := RDUniform.new()
        mpm_iap_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_iap_pos_b.binding = 2
        mpm_iap_pos_b.add_id(_mpm_pos_mass_b_rid)
        _mpm_island_apply_set_b = _rd.uniform_set_create(
            [mpm_iap_vel_b, mpm_iap_c_b, mpm_iap_pos_b, mpm_iap_meta, mpm_iap_count, mpm_iap_cm, mpm_iap_v, mpm_iap_L, mpm_iap_I0, mpm_iap_I1],
            _mpm_island_apply_shader_rid,
            0
        )

    # MPM stats uniform sets (optional).
    if _mpm_stats_init_shader_rid.is_valid() and _mpm_stats_rid.is_valid():
        var mpm_stats_init_out := RDUniform.new()
        mpm_stats_init_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_init_out.binding = 0
        mpm_stats_init_out.add_id(_mpm_stats_rid)
        _mpm_stats_init_set = _rd.uniform_set_create([mpm_stats_init_out], _mpm_stats_init_shader_rid, 0)

    if _mpm_stats_shader_rid.is_valid() and _mpm_stats_rid.is_valid():
        var mpm_stats_ubo := RDUniform.new()
        mpm_stats_ubo.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
        mpm_stats_ubo.binding = 0
        mpm_stats_ubo.add_id(_ubo_rid)
        var mpm_stats_ind := RDUniform.new()
        mpm_stats_ind.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_ind.binding = 1
        mpm_stats_ind.add_id(_indirection_rid)
        var mpm_stats_static := RDUniform.new()
        mpm_stats_static.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_static.binding = 2
        mpm_stats_static.add_id(_atlas_static_rid)
        var mpm_stats_meta := RDUniform.new()
        mpm_stats_meta.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_meta.binding = 5
        mpm_stats_meta.add_id(_mpm_meta_rid)
        var mpm_stats_count := RDUniform.new()
        mpm_stats_count.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_count.binding = 6
        mpm_stats_count.add_id(_mpm_particle_count_rid)
        var mpm_stats_out := RDUniform.new()
        mpm_stats_out.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_out.binding = 7
        mpm_stats_out.add_id(_mpm_stats_rid)

        var mpm_stats_pos_a := RDUniform.new()
        mpm_stats_pos_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_pos_a.binding = 3
        mpm_stats_pos_a.add_id(_mpm_pos_mass_a_rid)
        var mpm_stats_vel_a := RDUniform.new()
        mpm_stats_vel_a.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_vel_a.binding = 4
        mpm_stats_vel_a.add_id(_mpm_vel_vol_a_rid)
        _mpm_stats_set_a = _rd.uniform_set_create(
            [mpm_stats_ubo, mpm_stats_ind, mpm_stats_static, mpm_stats_pos_a, mpm_stats_vel_a, mpm_stats_meta, mpm_stats_count, mpm_stats_out],
            _mpm_stats_shader_rid,
            0
        )

        var mpm_stats_pos_b := RDUniform.new()
        mpm_stats_pos_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_pos_b.binding = 3
        mpm_stats_pos_b.add_id(_mpm_pos_mass_b_rid)
        var mpm_stats_vel_b := RDUniform.new()
        mpm_stats_vel_b.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
        mpm_stats_vel_b.binding = 4
        mpm_stats_vel_b.add_id(_mpm_vel_vol_b_rid)
        _mpm_stats_set_b = _rd.uniform_set_create(
            [mpm_stats_ubo, mpm_stats_ind, mpm_stats_static, mpm_stats_pos_b, mpm_stats_vel_b, mpm_stats_meta, mpm_stats_count, mpm_stats_out],
            _mpm_stats_shader_rid,
            0
        )

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

    var dt: float = 0.0
    var debug_w := float(_sim_frame % 4)
    # Implementation detail: some MPM shaders need to branch on fracture enabled/disabled
    # without changing the shared Params UBO layout. We encode it in world_rot_x.w.
    var fracture_flag := 1.0 if mpm_fracture_enabled else 0.0
    if sim_enabled and sim_mode == 1:
        var substeps: int = maxi(1, mpm_substeps)
        dt = maxf(0.0, mpm_dt) / float(substeps)
        debug_w = float(mpm_gravity_strength)
    var params := PackedFloat32Array([
        grid_extent, grid_extent, grid_extent, dt,
        origin.x, origin.y, origin.z, 0.0,
        pos.x, pos.y, pos.z, 0.0,
        basis.x.x, basis.x.y, basis.x.z, 0.0,
        basis.y.x, basis.y.y, basis.y.z, 0.0,
        -basis.z.x, -basis.z.y, -basis.z.z, 0.0,
        float(width), float(height), tan_half_fov, aspect,
        voxel_size, effective_max_distance, 0.8, 0.25,
        brick_grid, brick_grid, brick_grid, float(chunk_size),
        gravity.x, gravity.y, gravity.z, debug_w,
        world_basis.x.x, world_basis.x.y, world_basis.x.z, fracture_flag,
        world_basis.y.x, world_basis.y.y, world_basis.y.z, 0.0,
        world_basis.z.x, world_basis.z.y, world_basis.z.z, 0.0
    ])
    var bytes := params.to_byte_array()
    _update_params(bytes)
    _debug_log_snapshot(pos, basis, world_extent)
    _reset_metrics()
    if sim_enabled and sim_mode == 1:
        _dispatch_mpm()
        _dispatch_occupancy()
    else:
        _dispatch_occupancy()
        if sim_enabled and sim_mode == 0:
            _dispatch_active_list()
            _dispatch_active_dispatch()
            _dispatch_sim(grid_extent_i)
    _dispatch_light(grid_extent_i)
    _dispatch_compute()
    _readback_metrics()
    _readback_mpm_stats()
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
    if sim_mode != 0:
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

func _dispatch_mpm() -> void:
    if !_mpm_p2g_pipeline_rid.is_valid() or !_mpm_grid_update_pipeline_rid.is_valid() or !_mpm_g2p_advect_pipeline_rid.is_valid():
        return
    if !_mpm_grid_uniform_set.is_valid():
        return
    var every: int = sim_every
    if every < 1:
        every = 1
    _sim_frame += 1
    if _sim_frame % every != 0:
        return

    var max_p: int = maxi(1, mpm_max_particles)
    var particle_groups := int(ceil(float(max_p) / 128.0))
    var total_cells := int(_atlas_bytes / 4)
    var grid_groups := int(ceil(float(total_cells) / 256.0))
    var grid_bytes := total_cells * 16
    var substeps: int = maxi(1, mpm_substeps)
    var rigid_map_bytes := total_cells * 4
    var cell_pos_bytes := total_cells * 16
    var island_count := max_p + 1
    var island_groups := int(ceil(float(island_count) / 256.0))
    var island_bytes := island_groups * 256 * 16

    var islands_ok := (
        mpm_rigid_enabled
        and _mpm_build_rigid_map_pipeline_rid.is_valid()
        and _mpm_update_bonds_pipeline_rid.is_valid()
        and _mpm_ccl_init_pipeline_rid.is_valid()
        and _mpm_ccl_propagate_pipeline_rid.is_valid()
        and _mpm_ccl_write_pipeline_rid.is_valid()
    )
    if islands_ok and !_mpm_islands_ready:
        _dispatch_mpm_islands(particle_groups, rigid_map_bytes)
        _mpm_islands_ready = true

    for _s in range(substeps):
        if mpm_rigid_enabled and _mpm_island_accum0_pipeline_rid.is_valid() and _mpm_island_finalize_pipeline_rid.is_valid() and _mpm_island_accum1_pipeline_rid.is_valid() and _mpm_island_apply_pipeline_rid.is_valid():
            var accum0_set := _mpm_island_accum0_set_a if _mpm_particles_use_a else _mpm_island_accum0_set_b
            var accum1_set := _mpm_island_accum1_set_a if _mpm_particles_use_a else _mpm_island_accum1_set_b
            var apply_set := _mpm_island_apply_set_a if _mpm_particles_use_a else _mpm_island_apply_set_b
            if accum0_set.is_valid() and accum1_set.is_valid() and apply_set.is_valid() and _mpm_island_finalize_set.is_valid():
                _rd.buffer_clear(_mpm_island_mass_mom_rid, 0, island_bytes)
                _rd.buffer_clear(_mpm_island_mass_com_rid, 0, island_bytes)
                _rd.buffer_clear(_mpm_island_L_rid, 0, island_bytes)
                _rd.buffer_clear(_mpm_island_I0_rid, 0, island_bytes)
                _rd.buffer_clear(_mpm_island_I1_rid, 0, island_bytes)

                var list_ia0 := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_ia0, _mpm_island_accum0_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_ia0, accum0_set, 0)
                _rd.compute_list_dispatch(list_ia0, particle_groups, 1, 1)
                _rd.compute_list_end()

                var list_if := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_if, _mpm_island_finalize_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_if, _mpm_island_finalize_set, 0)
                _rd.compute_list_dispatch(list_if, island_groups, 1, 1)
                _rd.compute_list_end()

                var list_ia1 := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_ia1, _mpm_island_accum1_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_ia1, accum1_set, 0)
                _rd.compute_list_dispatch(list_ia1, particle_groups, 1, 1)
                _rd.compute_list_end()

                var list_iap := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_iap, _mpm_island_apply_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_iap, apply_set, 0)
                _rd.compute_list_dispatch(list_iap, particle_groups, 1, 1)
                _rd.compute_list_end()

        if _mpm_grid_accum_rid.is_valid():
            _rd.buffer_clear(_mpm_grid_accum_rid, 0, grid_bytes)
        if _mpm_grid_vel_rid.is_valid():
            _rd.buffer_clear(_mpm_grid_vel_rid, 0, grid_bytes)

        var p2g_set := _mpm_p2g_uniform_set_a if _mpm_particles_use_a else _mpm_p2g_uniform_set_b
        if p2g_set.is_valid():
            var list := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list, _mpm_p2g_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list, p2g_set, 0)
            _rd.compute_list_dispatch(list, particle_groups, 1, 1)
            _rd.compute_list_end()

        var list_grid := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(list_grid, _mpm_grid_update_pipeline_rid)
        _rd.compute_list_bind_uniform_set(list_grid, _mpm_grid_uniform_set, 0)
        _rd.compute_list_dispatch(list_grid, grid_groups, 1, 1)
        _rd.compute_list_end()

        var g2p_set := _mpm_g2p_uniform_set_ab if _mpm_particles_use_a else _mpm_g2p_uniform_set_ba
        if g2p_set.is_valid():
            var list_g2p := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list_g2p, _mpm_g2p_advect_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list_g2p, g2p_set, 0)
            _rd.compute_list_dispatch(list_g2p, particle_groups, 1, 1)
            _rd.compute_list_end()

        _mpm_particles_use_a = !_mpm_particles_use_a

    if islands_ok and mpm_fracture_enabled:
        _dispatch_mpm_islands(particle_groups, rigid_map_bytes)

    var atlas_target_a := _mpm_particles_use_a
    if _mpm_copy_static_pipeline_rid.is_valid():
        var copy_set := _mpm_copy_uniform_set_a if atlas_target_a else _mpm_copy_uniform_set_b
        if copy_set.is_valid():
            var list_copy := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list_copy, _mpm_copy_static_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list_copy, copy_set, 0)
            _rd.compute_list_dispatch(list_copy, grid_groups, 1, 1)
            _rd.compute_list_end()

    if _mpm_cell_pos_rid.is_valid():
        _rd.buffer_clear(_mpm_cell_pos_rid, 0, cell_pos_bytes)

    if _mpm_particles_to_atlas_pipeline_rid.is_valid():
        var to_atlas_set := _mpm_particles_to_atlas_uniform_set_a if atlas_target_a else _mpm_particles_to_atlas_uniform_set_b
        if to_atlas_set.is_valid():
            var list_atlas := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list_atlas, _mpm_particles_to_atlas_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list_atlas, to_atlas_set, 0)
            _rd.compute_list_dispatch(list_atlas, particle_groups, 1, 1)
            _rd.compute_list_end()
    elif _mpm_grid_to_atlas_pipeline_rid.is_valid():
        var to_atlas_set2 := _mpm_grid_to_atlas_uniform_set_a if atlas_target_a else _mpm_grid_to_atlas_uniform_set_b
        if to_atlas_set2.is_valid():
            var list_atlas2 := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list_atlas2, _mpm_grid_to_atlas_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list_atlas2, to_atlas_set2, 0)
            _rd.compute_list_dispatch(list_atlas2, grid_groups, 1, 1)
            _rd.compute_list_end()

    # Optional stats pass for autonomous regression testing.
    if mpm_stats_enabled and _mpm_stats_rid.is_valid() and _mpm_stats_init_pipeline_rid.is_valid() and _mpm_stats_pipeline_rid.is_valid():
        _mpm_stats_frame += 1
        var stats_every: int = mpm_stats_every
        if stats_every < 1:
            stats_every = 1
        if _mpm_stats_frame % stats_every == 0:
            if _mpm_stats_init_set.is_valid():
                var list_si := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_si, _mpm_stats_init_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_si, _mpm_stats_init_set, 0)
                _rd.compute_list_dispatch(list_si, 1, 1, 1)
                _rd.compute_list_end()
            var stats_set := _mpm_stats_set_a if _mpm_particles_use_a else _mpm_stats_set_b
            if stats_set.is_valid():
                var list_s := _rd.compute_list_begin()
                _rd.compute_list_bind_compute_pipeline(list_s, _mpm_stats_pipeline_rid)
                _rd.compute_list_bind_uniform_set(list_s, stats_set, 0)
                _rd.compute_list_dispatch(list_s, particle_groups, 1, 1)
                _rd.compute_list_end()

    _atlas_use_a = atlas_target_a

func _dispatch_mpm_islands(particle_groups: int, rigid_map_bytes: int) -> void:
    if _rd == null:
        return
    if !_mpm_build_rigid_map_pipeline_rid.is_valid() or !_mpm_update_bonds_pipeline_rid.is_valid():
        return
    if !_mpm_ccl_init_pipeline_rid.is_valid() or !_mpm_ccl_propagate_pipeline_rid.is_valid() or !_mpm_ccl_write_pipeline_rid.is_valid():
        return

    if _mpm_rigid_map_rid.is_valid():
        _rd.buffer_clear(_mpm_rigid_map_rid, 0, rigid_map_bytes)

    var rm_set := _mpm_rigid_map_set_a if _mpm_particles_use_a else _mpm_rigid_map_set_b
    if rm_set.is_valid():
        var list_rm := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(list_rm, _mpm_build_rigid_map_pipeline_rid)
        _rd.compute_list_bind_uniform_set(list_rm, rm_set, 0)
        _rd.compute_list_dispatch(list_rm, particle_groups, 1, 1)
        _rd.compute_list_end()

    var bonds_set := _mpm_update_bonds_set_a if _mpm_particles_use_a else _mpm_update_bonds_set_b
    if bonds_set.is_valid():
        var list_bonds := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(list_bonds, _mpm_update_bonds_pipeline_rid)
        _rd.compute_list_bind_uniform_set(list_bonds, bonds_set, 0)
        _rd.compute_list_dispatch(list_bonds, particle_groups, 1, 1)
        _rd.compute_list_end()

    if _mpm_ccl_init_set_a.is_valid():
        var list_ci := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(list_ci, _mpm_ccl_init_pipeline_rid)
        _rd.compute_list_bind_uniform_set(list_ci, _mpm_ccl_init_set_a, 0)
        _rd.compute_list_dispatch(list_ci, particle_groups, 1, 1)
        _rd.compute_list_end()

    var use_labels_a := true
    var iters := maxi(0, mpm_ccl_iterations)
    for _i in range(iters):
        var prop_set: RID = RID()
        if _mpm_particles_use_a:
            prop_set = _mpm_ccl_prop_set_a_ab if use_labels_a else _mpm_ccl_prop_set_a_ba
        else:
            prop_set = _mpm_ccl_prop_set_b_ab if use_labels_a else _mpm_ccl_prop_set_b_ba
        if prop_set.is_valid():
            var list_cp := _rd.compute_list_begin()
            _rd.compute_list_bind_compute_pipeline(list_cp, _mpm_ccl_propagate_pipeline_rid)
            _rd.compute_list_bind_uniform_set(list_cp, prop_set, 0)
            _rd.compute_list_dispatch(list_cp, particle_groups, 1, 1)
            _rd.compute_list_end()
            use_labels_a = !use_labels_a

    var write_set := _mpm_ccl_write_set_a if use_labels_a else _mpm_ccl_write_set_b
    if write_set.is_valid():
        var list_cw := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(list_cw, _mpm_ccl_write_pipeline_rid)
        _rd.compute_list_bind_uniform_set(list_cw, write_set, 0)
        _rd.compute_list_dispatch(list_cw, particle_groups, 1, 1)
        _rd.compute_list_end()

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
    if !debug_logging and !diag_enabled:
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
    # active_bricks only has meaning for the legacy CA path (sim_mode==0).
    if sim_mode == 0 and _active_count_rid.is_valid():
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

func _readback_mpm_stats() -> void:
    if !mpm_stats_enabled:
        return
    if sim_mode != 1 or !sim_enabled:
        return
    var every: int = mpm_stats_every
    if every < 1:
        every = 1
    if _mpm_stats_frame == 0 or (_mpm_stats_frame % every) != 0:
        return
    if _mpm_stats_frame == _mpm_stats_last_readback:
        return
    _mpm_stats_last_readback = _mpm_stats_frame
    if !_mpm_stats_rid.is_valid():
        return
    RenderingServer.call_on_render_thread(Callable(self, "_readback_mpm_stats_on_render_thread"))

func _readback_mpm_stats_on_render_thread() -> void:
    if _rd == null or !_mpm_stats_rid.is_valid():
        return
    var bytes := _rd.buffer_get_data(_mpm_stats_rid)
    var ints := bytes.to_int32_array()
    call_deferred("_apply_mpm_stats_ints", ints)

func _apply_mpm_stats_ints(ints: PackedInt32Array) -> void:
    if ints.size() < 8:
        return
    mpm_last_stats_raw = ints
    mpm_last_stats_frame += 1

    var out := {}
    out["version"] = ints[0]
    out["particle_count"] = ints[1]
    out["active"] = ints[2]
    out["inactive"] = ints[3]
    out["nan"] = ints[4]

    const IDX_BASE := 5
    const MAT_SLOTS := 16
    const SLOT_STRIDE := 14

    var slots: Array = []
    slots.resize(MAT_SLOTS)
    for mat_id in range(MAT_SLOTS):
        var base := IDX_BASE + mat_id * SLOT_STRIDE
        if base + (SLOT_STRIDE - 1) >= ints.size():
            break
        var count := ints[base + 0]
        var mass_fixed := ints[base + 1]
        var sum_speed := ints[base + 2]
        var max_speed := ints[base + 3]
        var overlap_static := ints[base + 4]

        var min_x := ints[base + 5]
        var min_y := ints[base + 6]
        var min_z := ints[base + 7]
        var max_x := ints[base + 8]
        var max_y := ints[base + 9]
        var max_z := ints[base + 10]

        var sum_mx := ints[base + 11]
        var sum_my := ints[base + 12]
        var sum_mz := ints[base + 13]

        var mass := float(mass_fixed) / 10000.0
        var avg_speed := 0.0
        if count > 0:
            avg_speed = (float(sum_speed) / 100.0) / float(count)
        var max_speed_f := float(max_speed) / 1000.0

        var com := Vector3.ZERO
        if mass_fixed != 0:
            # sum_mx = sum(m*x)*100, mass_fixed = sum(m)*10000 => com = sum_mx*100/mass_fixed
            com = Vector3(
                float(sum_mx) * 100.0 / float(mass_fixed),
                float(sum_my) * 100.0 / float(mass_fixed),
                float(sum_mz) * 100.0 / float(mass_fixed)
            )

        var bbox_valid := (count > 0 and min_x != 2147483647 and max_x != -2147483647)
        var bbox_min := Vector3(float(min_x) / 1000.0, float(min_y) / 1000.0, float(min_z) / 1000.0)
        var bbox_max := Vector3(float(max_x) / 1000.0, float(max_y) / 1000.0, float(max_z) / 1000.0)

        slots[mat_id] = {
            "mat_id": mat_id,
            "count": count,
            "mass": mass,
            "avg_speed": avg_speed,
            "max_speed": max_speed_f,
            "overlap_static": overlap_static,
            "com": com,
            "bbox_valid": bbox_valid,
            "bbox_min": bbox_min,
            "bbox_max": bbox_max,
        }

    out["slots"] = slots
    mpm_last_stats = out

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

func set_voxel_entries_mpm(entries: Array) -> void:
    if _rd == null:
        return
    _active_list_ready = false
    _mpm_islands_ready = false

    var brick_grid := chunk_grid
    var brick_count := brick_grid * brick_grid * brick_grid
    var cell_count := brick_count * chunk_size * chunk_size * chunk_size
    var grid_extent := brick_grid * chunk_size

    # MPM uses a full grid indirection so particles can move into empty space anywhere.
    var indirection := PackedInt32Array()
    indirection.resize(brick_count)
    for i in range(brick_count):
        indirection[i] = i + 1

    var static_atlas := PackedInt32Array()
    static_atlas.resize(cell_count)
    for i in range(cell_count):
        static_atlas[i] = 0

    var atlas_init := PackedInt32Array()
    atlas_init.resize(cell_count)
    for i in range(cell_count):
        atlas_init[i] = 0

    var pos_mass := PackedFloat32Array()
    var vel_vol := PackedFloat32Array()
    var meta := PackedInt32Array()
    var count := 0
    var max_p: int = maxi(1, mpm_max_particles)

    # Mass is also stored in materials.json. Use that if available.
    var mass_by_id: Dictionary = {
        1: 1.6,
        2: 1.0,
        3: 0.05,
        8: 3.0,
        9: 3.0
    }
    if !material_data_path.is_empty() and FileAccess.file_exists(material_data_path):
        var mat_text := FileAccess.get_file_as_string(material_data_path)
        if !mat_text.is_empty():
            var parsed: Variant = JSON.parse_string(mat_text)
            if typeof(parsed) == TYPE_DICTIONARY:
                var parsed_dict: Dictionary = parsed
                var mats: Array = parsed_dict.get("materials", [])
                if typeof(mats) == TYPE_ARRAY:
                    for item in mats:
                        if typeof(item) != TYPE_DICTIONARY:
                            continue
                        var id := int(item.get("id", -1))
                        if id <= 0:
                            continue
                        mass_by_id[id] = float(item.get("mass", 1.0))

    for entry in entries:
        var pos = entry.get("pos", Vector3.ZERO)
        var mat_id = int(entry.get("material", 1))
        var flags = int(entry.get("flags", 0))
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

        if mat_id == 8 or mat_id == 9:
            static_atlas[local_index] = mat_id
            atlas_init[local_index] = mat_id
            continue

        if count >= max_p:
            continue
        var p_mass: float = float(mass_by_id.get(mat_id, 1.0))
        # pos_mass vec4
        pos_mass.append(float(gx))
        pos_mass.append(float(gy))
        pos_mass.append(float(gz))
        pos_mass.append(p_mass) # mass
        # vel_vol vec4
        vel_vol.append(0.0)
        vel_vol.append(0.0)
        vel_vol.append(0.0)
        vel_vol.append(1.0) # volume
        # meta uvec4 packed as int32
        meta.append(mat_id)
        meta.append(flags) # flags (bitmask; e.g., static bedrock)
        meta.append(0) # bond_mask
        meta.append(0) # island_id

        # Seed the render atlas so it shows immediately (no overlap handling).
        if atlas_init[local_index] == 0:
            atlas_init[local_index] = mat_id
        count += 1

    var ind_bytes := indirection.to_byte_array()
    _rd.buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes)
    _indirection_cpu = indirection

    var static_bytes := static_atlas.to_byte_array()
    if _atlas_static_rid.is_valid():
        _rd.buffer_update(_atlas_static_rid, 0, static_bytes.size(), static_bytes)

    # Upload initial render atlas (static + initial particle snaps).
    var atlas_bytes := atlas_init.to_byte_array()
    if _atlas_a_rid.is_valid():
        _rd.buffer_update(_atlas_a_rid, 0, atlas_bytes.size(), atlas_bytes)
    if _atlas_b_rid.is_valid():
        _rd.buffer_update(_atlas_b_rid, 0, atlas_bytes.size(), atlas_bytes)
    _atlas_use_a = true

    # Upload particle buffers (A and B start identical).
    var pos_bytes := pos_mass.to_byte_array()
    var vel_bytes := vel_vol.to_byte_array()
    if _mpm_pos_mass_a_rid.is_valid() and pos_bytes.size() > 0:
        _rd.buffer_update(_mpm_pos_mass_a_rid, 0, pos_bytes.size(), pos_bytes)
    if _mpm_pos_mass_b_rid.is_valid() and pos_bytes.size() > 0:
        _rd.buffer_update(_mpm_pos_mass_b_rid, 0, pos_bytes.size(), pos_bytes)
    if _mpm_vel_vol_a_rid.is_valid() and vel_bytes.size() > 0:
        _rd.buffer_update(_mpm_vel_vol_a_rid, 0, vel_bytes.size(), vel_bytes)
    if _mpm_vel_vol_b_rid.is_valid() and vel_bytes.size() > 0:
        _rd.buffer_update(_mpm_vel_vol_b_rid, 0, vel_bytes.size(), vel_bytes)
    var meta_bytes := meta.to_byte_array()
    if _mpm_meta_rid.is_valid() and meta_bytes.size() > 0:
        _rd.buffer_update(_mpm_meta_rid, 0, meta_bytes.size(), meta_bytes)
    if _mpm_particle_count_rid.is_valid():
        var count_bytes := PackedInt32Array([count]).to_byte_array()
        _rd.buffer_update(_mpm_particle_count_rid, 0, count_bytes.size(), count_bytes)
    _mpm_particle_count_cpu = count

    # Reset deformation state and initialize F=I on the GPU (C=0).
    var particle_mat3_bytes: int = max_p * 48
    if _mpm_c_a_rid.is_valid():
        _rd.buffer_clear(_mpm_c_a_rid, 0, particle_mat3_bytes)
    if _mpm_c_b_rid.is_valid():
        _rd.buffer_clear(_mpm_c_b_rid, 0, particle_mat3_bytes)
    if _mpm_f_a_rid.is_valid():
        _rd.buffer_clear(_mpm_f_a_rid, 0, particle_mat3_bytes)
    if _mpm_f_b_rid.is_valid():
        _rd.buffer_clear(_mpm_f_b_rid, 0, particle_mat3_bytes)
    if _mpm_init_particles_pipeline_rid.is_valid() and _mpm_init_uniform_set.is_valid() and count > 0:
        var groups := int(ceil(float(count) / 128.0))
        var init_list := _rd.compute_list_begin()
        _rd.compute_list_bind_compute_pipeline(init_list, _mpm_init_particles_pipeline_rid)
        _rd.compute_list_bind_uniform_set(init_list, _mpm_init_uniform_set, 0)
        _rd.compute_list_dispatch(init_list, groups, 1, 1)
        _rd.compute_list_end()

    _mpm_particles_use_a = true

    if _light_a_rid.is_valid():
        _rd.buffer_clear(_light_a_rid, 0, _atlas_bytes)
    if _light_b_rid.is_valid():
        _rd.buffer_clear(_light_b_rid, 0, _atlas_bytes)

    if diag_enabled:
        _diag("set_voxel_entries_mpm entries=%d particles=%d grid_extent=%d" % [entries.size(), count, grid_extent])

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
    # [mass, friction, cohesion, resistance, drag, support_bonus, lateral_bias, gravity_bias]
    var defaults := {
        1: {"mass": 1.6, "friction": 0.7, "cohesion": 0.4, "resistance": 0.6, "drag": 0.35, "support_bonus": 0.25, "lateral_bias": -0.15, "gravity_bias": 1.2},
        2: {"mass": 1.0, "friction": 0.05, "cohesion": 0.1, "resistance": 0.1, "drag": 0.15, "support_bonus": 0.15, "lateral_bias": 0.2, "gravity_bias": 1.0},
        3: {"mass": 0.05, "friction": 0.0, "cohesion": 0.0, "resistance": 0.0, "drag": 0.01, "support_bonus": 0.0, "lateral_bias": 0.0, "gravity_bias": 0.0},
        4: {"mass": 4.0, "friction": 1.0, "cohesion": 1.5, "resistance": 8.0, "drag": 0.2, "support_bonus": 0.0, "lateral_bias": -0.5, "gravity_bias": 0.0},
        8: {"mass": 3.0, "friction": 10.0, "cohesion": 2.0, "resistance": 10.0, "drag": 2.0, "support_bonus": 0.0, "lateral_bias": -1.0, "gravity_bias": 0.0},
        9: {"mass": 3.0, "friction": 10.0, "cohesion": 2.0, "resistance": 10.0, "drag": 2.0, "support_bonus": 0.0, "lateral_bias": -1.0, "gravity_bias": 0.0}
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
    _material_mass_by_id = {}
    for i in range(count):
        var src: Dictionary = materials.get(i, defaults.get(i, {}))
        if typeof(src) != TYPE_DICTIONARY:
            src = {}
        var mass_val: float = float(src.get("mass", 0.0))
        floats[i * 8 + 0] = mass_val
        _material_mass_by_id[i] = mass_val
        floats[i * 8 + 1] = float(src.get("friction", 0.0))
        floats[i * 8 + 2] = float(src.get("cohesion", 0.0))
        floats[i * 8 + 3] = float(src.get("resistance", 0.0))
        floats[i * 8 + 4] = float(src.get("drag", 0.0))
        floats[i * 8 + 5] = float(src.get("support_bonus", 0.0))
        floats[i * 8 + 6] = float(src.get("lateral_bias", 0.0))
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

func debug_mpm_hourglass_metrics(
        sand_id: int,
        center: float,
        half: float,
        bulb_radius: float,
        neck_radius: float,
        wall_thickness: int,
        shell_padding: float,
        inner_wall: float,
        every: int = 60
    ) -> void:
    if _rd == null:
        return
    if sim_mode != 1:
        return
    if every < 1:
        every = 1
    if _debug_frame % every != 0:
        return
    RenderingServer.call_on_render_thread(Callable(self, "_debug_mpm_hourglass_metrics_on_render_thread").bind(
        _debug_frame,
        sand_id,
        center,
        half,
        bulb_radius,
        neck_radius,
        wall_thickness,
        shell_padding,
        inner_wall
    ))

func _debug_mpm_hourglass_metrics_on_render_thread(
        frame_id: int,
        sand_id: int,
        center: float,
        half: float,
        bulb_radius: float,
        neck_radius: float,
        wall_thickness: int,
        shell_padding: float,
        inner_wall: float
    ) -> void:
    if _rd == null or !_mpm_particle_count_rid.is_valid() or !_mpm_meta_rid.is_valid():
        return
    var count_bytes := _rd.buffer_get_data(_mpm_particle_count_rid, 0, 4)
    if count_bytes.size() < 4:
        return
    var count_vals := count_bytes.to_int32_array()
    if count_vals.size() == 0:
        return
    var count := maxi(0, int(count_vals[0]))
    if count <= 0:
        print("MPM hourglass | frame=%d particles=0" % frame_id)
        return

    var pos_rid: RID = _mpm_pos_mass_a_rid if _mpm_particles_use_a else _mpm_pos_mass_b_rid
    var vel_rid: RID = _mpm_vel_vol_a_rid if _mpm_particles_use_a else _mpm_vel_vol_b_rid
    if !pos_rid.is_valid() or !vel_rid.is_valid():
        return

    var bytes_per_particle := 16 # vec4
    var max_bytes := count * bytes_per_particle
    var pos_bytes := _rd.buffer_get_data(pos_rid, 0, max_bytes)
    var vel_bytes := _rd.buffer_get_data(vel_rid, 0, max_bytes)
    var meta_bytes := _rd.buffer_get_data(_mpm_meta_rid, 0, max_bytes)
    if pos_bytes.size() < max_bytes or vel_bytes.size() < max_bytes or meta_bytes.size() < max_bytes:
        return

    var pos_vals := pos_bytes.to_float32_array()
    var vel_vals := vel_bytes.to_float32_array()
    var meta_vals := meta_bytes.to_int32_array()
    if pos_vals.size() < count * 4 or vel_vals.size() < count * 4 or meta_vals.size() < count * 4:
        return

    var grid_extent: int = chunk_grid * chunk_size
    var cap_min := float(wall_thickness)
    var cap_max := float(grid_extent - wall_thickness)
    var safe_half := maxf(half, 1.0)

    var sand_count := 0
    var sand_escaped := 0
    var sand_penetrating := 0
    var sand_cap := 0
    var sand_in_glass_cell := 0
    var sand_mass_total := 0.0
    var sand_unique_cells := 0
    var sand_max_per_cell := 0
    var y_min := 1e9
    var y_max := -1e9
    var max_speed := 0.0
    var sum_speed := 0.0
    var cell_counts := {}

    for i in range(count):
        var mat_id := meta_vals[i * 4 + 0]
        if mat_id != sand_id:
            continue
        sand_count += 1

        var x := pos_vals[i * 4 + 0]
        var y := pos_vals[i * 4 + 1]
        var z := pos_vals[i * 4 + 2]
        sand_mass_total += pos_vals[i * 4 + 3]
        y_min = minf(y_min, y)
        y_max = maxf(y_max, y)

        var vx := vel_vals[i * 4 + 0]
        var vy := vel_vals[i * 4 + 1]
        var vz := vel_vals[i * 4 + 2]
        var speed := sqrt(vx * vx + vy * vy + vz * vz)
        sum_speed += speed
        max_speed = maxf(max_speed, speed)

        # Quantize to BCC cell for "how many voxels should be visible" estimates.
        var cx := int(round(x * 0.5)) * 2
        var cy := int(round(y * 0.5)) * 2
        var cz := int(round(z * 0.5)) * 2
        # Choose even/odd lattice by checking the closest parity point.
        var ox := int(round((x - 1.0) * 0.5)) * 2 + 1
        var oy := int(round((y - 1.0) * 0.5)) * 2 + 1
        var oz := int(round((z - 1.0) * 0.5)) * 2 + 1
        var de2 := (x - float(cx)) * (x - float(cx)) + (y - float(cy)) * (y - float(cy)) + (z - float(cz)) * (z - float(cz))
        var do2 := (x - float(ox)) * (x - float(ox)) + (y - float(oy)) * (y - float(oy)) + (z - float(oz)) * (z - float(oz))
        var sx := cx
        var sy := cy
        var sz := cz
        if do2 < de2:
            sx = ox
            sy = oy
            sz = oz
        sx = clampi(sx, 0, grid_extent - 1)
        sy = clampi(sy, 0, grid_extent - 1)
        sz = clampi(sz, 0, grid_extent - 1)
        var key := sx + sy * grid_extent + sz * grid_extent * grid_extent
        var prev := int(cell_counts.get(key, 0))
        var next := prev + 1
        cell_counts[key] = next
        sand_max_per_cell = maxi(sand_max_per_cell, next)

        var cap := (y < cap_min) or (y >= cap_max)
        if cap:
            sand_cap += 1
            sand_penetrating += 1
            continue

        var dx := x - center
        var dz := z - center
        var r := sqrt(dx * dx + dz * dz)
        var t := absf(y - center) / safe_half
        t = clamp(t, 0.0, 1.0)
        var radius := neck_radius + (bulb_radius - neck_radius) * t
        var shell_inner := radius - inner_wall
        var shell_outer := radius + shell_padding

        var eps_outer := 0.25
        var eps_inner := 0.15
        if r > shell_outer + eps_outer:
            sand_escaped += 1
        elif r >= shell_inner - eps_inner:
            sand_penetrating += 1

        # Detect particles snapping into glass shell cells (these won't render because atlas keeps static glass).
        var cdx := float(sx) - center
        var cdz := float(sz) - center
        var cr := sqrt(cdx * cdx + cdz * cdz)
        var ct := absf(float(sy) - center) / safe_half
        ct = clamp(ct, 0.0, 1.0)
        var cradius := neck_radius + (bulb_radius - neck_radius) * ct
        var cshell_inner := cradius - inner_wall
        var cshell_outer := cradius + shell_padding
        var ccap := (sy < int(wall_thickness)) or (sy >= grid_extent - int(wall_thickness))
        var glass_cell := (cr >= cshell_inner and cr <= cshell_outer) or (ccap and cr <= (bulb_radius + shell_padding))
        if glass_cell:
            sand_in_glass_cell += 1

    var avg_speed := 0.0
    if sand_count > 0:
        avg_speed = sum_speed / float(sand_count)
        sand_unique_cells = cell_counts.size()
        var y_min_i := int(y_min) if y_min < 1e8 else -1
        var y_max_i := int(y_max) if y_max > -1e8 else -1

        # Render voxelization metrics: how many dynamic sand voxels actually made it into the atlas this frame.
        # This helps distinguish "true" mass loss from multiple particles landing in the same cell (render collapse).
        var rendered_total := -1
        var rendered_sand := -1
        var rendered_sand_outside := -1
        if _mpm_cell_pos_rid.is_valid() and _atlas_bytes > 0:
            var total_cells: int = int(_atlas_bytes / 4)
            var cp_bytes := _rd.buffer_get_data(_mpm_cell_pos_rid)
            var atlas_rid2: RID = _atlas_a_rid if _atlas_use_a else _atlas_b_rid
            if cp_bytes.size() >= total_cells * 16 and atlas_rid2.is_valid():
                var atlas_bytes := _rd.buffer_get_data(atlas_rid2)
                if atlas_bytes.size() >= total_cells * 4:
                    var cp_vals := cp_bytes.to_float32_array()
                    var atlas_vals := atlas_bytes.to_int32_array()
                    if cp_vals.size() >= total_cells * 4 and atlas_vals.size() >= total_cells:
                        var dyn_total := 0
                        var dyn_sand := 0
                        var dyn_sand_outside2 := 0
                        for ci in range(total_cells):
                            if cp_vals[ci * 4 + 3] > 0.5:
                                dyn_total += 1
                                if atlas_vals[ci] == sand_id:
                                    dyn_sand += 1
                                    # Count dynamic sand voxels that ended up outside the hourglass shell.
                                    var rx := cp_vals[ci * 4 + 0]
                                    var ry := cp_vals[ci * 4 + 1]
                                    var rz := cp_vals[ci * 4 + 2]
                                    var ddx := rx - center
                                    var ddz := rz - center
                                    var rr := sqrt(ddx * ddx + ddz * ddz)
                                    var tt := absf(ry - center) / safe_half
                                    tt = clamp(tt, 0.0, 1.0)
                                    var rradius := neck_radius + (bulb_radius - neck_radius) * tt
                                    var shell_outer2 := rradius + shell_padding
                                    if rr > shell_outer2 + 0.25:
                                        dyn_sand_outside2 += 1
                        rendered_total = dyn_total
                        rendered_sand = dyn_sand
                        rendered_sand_outside = dyn_sand_outside2

        print("MPM hourglass | frame=%d sand=%d mass=%.2f unique=%d max_per_cell=%d rendered_sand=%d rendered_total=%d rendered_outside=%d in_glass_cell=%d escaped=%d penetrating=%d cap=%d v_avg=%.3f v_max=%.3f y_min=%d y_max=%d" % [
            frame_id,
            sand_count,
            sand_mass_total,
            sand_unique_cells,
            sand_max_per_cell,
            rendered_sand,
            rendered_total,
            rendered_sand_outside,
            sand_in_glass_cell,
            sand_escaped,
            sand_penetrating,
            sand_cap,
        avg_speed,
        max_speed,
        y_min_i,
        y_max_i
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

func _snap_cell_in_bounds_to_bcc(cell: Vector3i) -> Vector3i:
    var grid_extent: int = chunk_grid * chunk_size
    if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    if _bcc_parity(cell):
        return cell
    # Try nudging one axis by +/- 1 to reach a valid BCC point.
    var offsets: Array[Vector3i] = [
        Vector3i(0, -1, 0),
        Vector3i(0, 1, 0),
        Vector3i(-1, 0, 0),
        Vector3i(1, 0, 0),
        Vector3i(0, 0, -1),
        Vector3i(0, 0, 1),
    ]
    for o in offsets:
        var c: Vector3i = cell + o
        if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= grid_extent or c.y >= grid_extent or c.z >= grid_extent:
            continue
        if _bcc_parity(c):
            return c
    return Vector3i(-1, -1, -1)

func _mpm_set_static_cell(cell: Vector3i, material: int) -> void:
    if _rd == null:
        return
    if !_atlas_static_rid.is_valid():
        return
    var atlas_index := _atlas_index_for_cell(cell)
    if atlas_index < 0:
        return
    var bytes := PackedInt32Array([material]).to_byte_array()
    var offset := atlas_index * 4
    _rd.buffer_update(_atlas_static_rid, offset, bytes.size(), bytes)
    # Mirror into both render atlases so it shows immediately (MPM copy-static runs next frame).
    if _atlas_a_rid.is_valid():
        _rd.buffer_update(_atlas_a_rid, offset, bytes.size(), bytes)
    if _atlas_b_rid.is_valid():
        _rd.buffer_update(_atlas_b_rid, offset, bytes.size(), bytes)

func mpm_spawn_cells(cells: Array, material: int, velocity: Vector3 = Vector3.ZERO, volume: float = 1.0, flags: int = 0) -> int:
    if _rd == null:
        return 0
    if sim_mode != 1:
        return 0
    if !_mpm_particle_count_rid.is_valid() or !_mpm_meta_rid.is_valid():
        return 0
    if !_mpm_pos_mass_a_rid.is_valid() or !_mpm_pos_mass_b_rid.is_valid():
        return 0
    if !_mpm_vel_vol_a_rid.is_valid() or !_mpm_vel_vol_b_rid.is_valid():
        return 0
    if !_mpm_c_a_rid.is_valid() or !_mpm_c_b_rid.is_valid() or !_mpm_f_a_rid.is_valid() or !_mpm_f_b_rid.is_valid():
        return 0
    if cells.size() == 0 or material <= 0:
        return 0

    var max_p: int = maxi(1, mpm_max_particles)
    var start: int = clampi(_mpm_particle_count_cpu, 0, max_p)
    if start >= max_p:
        return 0

    var snapped: Array = []
    snapped.resize(0)
    for c in cells:
        if typeof(c) != TYPE_VECTOR3I:
            continue
        var s := _snap_cell_in_bounds_to_bcc(c)
        if s.x < 0:
            continue
        snapped.append(s)
        if start + snapped.size() >= max_p:
            break

    var n: int = snapped.size()
    if n <= 0:
        return 0

    var mass_val: float = float(_material_mass_by_id.get(material, 1.0))
    if mass_val <= 0.0:
        mass_val = 1.0
    var vol_val: float = maxf(0.0, volume)

    var pos_f := PackedFloat32Array()
    pos_f.resize(n * 4)
    var vel_f := PackedFloat32Array()
    vel_f.resize(n * 4)
    var meta_i := PackedInt32Array()
    meta_i.resize(n * 4)
    var c_f := PackedFloat32Array()
    c_f.resize(n * 12) # mat3 in std430: 3 vec4 columns (padding)
    var f_f := PackedFloat32Array()
    f_f.resize(n * 12)

    for i in range(n):
        var cell: Vector3i = snapped[i]

        pos_f[i * 4 + 0] = float(cell.x)
        pos_f[i * 4 + 1] = float(cell.y)
        pos_f[i * 4 + 2] = float(cell.z)
        pos_f[i * 4 + 3] = mass_val

        vel_f[i * 4 + 0] = velocity.x
        vel_f[i * 4 + 1] = velocity.y
        vel_f[i * 4 + 2] = velocity.z
        vel_f[i * 4 + 3] = vol_val

        meta_i[i * 4 + 0] = material
        meta_i[i * 4 + 1] = flags # flags
        meta_i[i * 4 + 2] = 0 # bond_mask
        meta_i[i * 4 + 3] = 0 # island_id

        # C starts at 0; resize() already filled zeros.

        # F starts at identity; mat3 is stored as 3 vec4 columns in std430.
        var fi := i * 12
        f_f[fi + 0] = 1.0
        f_f[fi + 5] = 1.0
        f_f[fi + 10] = 1.0

    var pos_bytes := pos_f.to_byte_array()
    var vel_bytes := vel_f.to_byte_array()
    var meta_bytes := meta_i.to_byte_array()
    var c_bytes := c_f.to_byte_array()
    var f_bytes := f_f.to_byte_array()

    var p_off: int = start * 16
    var m_off: int = start * 16
    var mat_off: int = start * 48

    _rd.buffer_update(_mpm_pos_mass_a_rid, p_off, pos_bytes.size(), pos_bytes)
    _rd.buffer_update(_mpm_pos_mass_b_rid, p_off, pos_bytes.size(), pos_bytes)
    _rd.buffer_update(_mpm_vel_vol_a_rid, p_off, vel_bytes.size(), vel_bytes)
    _rd.buffer_update(_mpm_vel_vol_b_rid, p_off, vel_bytes.size(), vel_bytes)
    _rd.buffer_update(_mpm_meta_rid, m_off, meta_bytes.size(), meta_bytes)
    _rd.buffer_update(_mpm_c_a_rid, mat_off, c_bytes.size(), c_bytes)
    _rd.buffer_update(_mpm_c_b_rid, mat_off, c_bytes.size(), c_bytes)
    _rd.buffer_update(_mpm_f_a_rid, mat_off, f_bytes.size(), f_bytes)
    _rd.buffer_update(_mpm_f_b_rid, mat_off, f_bytes.size(), f_bytes)

    var new_count: int = start + n
    var count_bytes := PackedInt32Array([new_count]).to_byte_array()
    _rd.buffer_update(_mpm_particle_count_rid, 0, count_bytes.size(), count_bytes)
    _mpm_particle_count_cpu = new_count
    return n

func mpm_spawn_particle(cell: Vector3i, material: int, velocity: Vector3 = Vector3.ZERO, flags: int = 0) -> bool:
    return mpm_spawn_cells([cell], material, velocity, 1.0, flags) > 0

func set_voxel_at(cell: Vector3i, material: int) -> void:
    if _rd == null:
        return
    if sim_mode == 1:
        var c := _snap_cell_in_bounds_to_bcc(cell)
        if c.x < 0:
            print("VoxelRenderer set_voxel_at (MPM) | invalid cell=%s" % str(cell))
            return
        if material == 8 or material == 9:
            _mpm_set_static_cell(c, material)
            return
        if material > 0:
            mpm_spawn_particle(c, material)
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

func debug_material_column_metrics(mat_id: int) -> void:
    if _rd == null or !_atlas_a_rid.is_valid() or _indirection_cpu.size() == 0:
        print("VoxelRenderer columns | rd/indirection unavailable")
        return
    var atlas_rid := _atlas_a_rid if _atlas_use_a else _atlas_b_rid
    if !atlas_rid.is_valid():
        print("VoxelRenderer columns | atlas rid invalid")
        return
    var atlas_bytes := _rd.buffer_get_data(atlas_rid)
    var atlas_vals := atlas_bytes.to_int32_array()
    var grid_extent: int = chunk_grid * chunk_size
    var min_h := 1e9
    var max_h := -1e9
    var sum_h := 0.0
    var count := 0
    for z in range(grid_extent):
        for x in range(grid_extent):
            var h := -1
            for y in range(grid_extent - 1, -1, -1):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var idx := _atlas_index_for_cell(Vector3i(x, y, z))
                if idx <= 0 or idx >= atlas_vals.size():
                    continue
                if atlas_vals[idx] == mat_id:
                    h = y
                    break
            if h >= 0:
                min_h = min(min_h, h)
                max_h = max(max_h, h)
                sum_h += h
                count += 1
    if count == 0:
        print("VoxelRenderer columns | mat=%d no columns" % mat_id)
        return
    var avg_h := sum_h / float(count)
    var variance := 0.0
    for z in range(grid_extent):
        for x in range(grid_extent):
            var h := -1
            for y in range(grid_extent - 1, -1, -1):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var idx := _atlas_index_for_cell(Vector3i(x, y, z))
                if idx <= 0 or idx >= atlas_vals.size():
                    continue
                if atlas_vals[idx] == mat_id:
                    h = y
                    break
            if h >= 0:
                var d := float(h) - avg_h
                variance += d * d
    variance /= float(count)
    print("VoxelRenderer columns | mat=%d columns=%d min=%d max=%d avg=%.2f var=%.2f" % [
        mat_id, count, int(min_h), int(max_h), avg_h, variance
    ])

func debug_water_depth_metrics(water_id: int) -> void:
    if _rd == null or !_atlas_a_rid.is_valid() or _indirection_cpu.size() == 0:
        print("VoxelRenderer depth | rd/indirection unavailable")
        return
    var atlas_rid := _atlas_a_rid if _atlas_use_a else _atlas_b_rid
    if !atlas_rid.is_valid():
        print("VoxelRenderer depth | atlas rid invalid")
        return
    var atlas_bytes := _rd.buffer_get_data(atlas_rid)
    var atlas_vals := atlas_bytes.to_int32_array()
    var grid_extent: int = chunk_grid * chunk_size
    var min_d := 1e9
    var max_d := -1e9
    var sum_d := 0.0
    var count := 0
    for z in range(grid_extent):
        for x in range(grid_extent):
            var water_y := -1
            var base_y := -1
            for y in range(grid_extent - 1, -1, -1):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                var idx := _atlas_index_for_cell(Vector3i(x, y, z))
                if idx <= 0 or idx >= atlas_vals.size():
                    continue
                var val := atlas_vals[idx]
                if water_y < 0:
                    if val == water_id:
                        water_y = y
                    continue
                if val != 0 and val != water_id:
                    base_y = y
                    break
            if water_y >= 0:
                var depth := water_y - base_y
                min_d = min(min_d, depth)
                max_d = max(max_d, depth)
                sum_d += depth
                count += 1
    if count == 0:
        print("VoxelRenderer depth | water=%d no columns" % water_id)
        return
    var avg_d := sum_d / float(count)
    print("VoxelRenderer depth | water=%d columns=%d min=%d max=%d avg=%.2f" % [
        water_id, count, int(min_d), int(max_d), avg_d
    ])


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
    if _display_material != null:
        _display_material.set_shader_parameter("compute_tex", null)
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
    if _mpm_copy_uniform_set_a.is_valid():
        _rd.free_rid(_mpm_copy_uniform_set_a)
    if _mpm_copy_uniform_set_b.is_valid():
        _rd.free_rid(_mpm_copy_uniform_set_b)
    if _mpm_init_uniform_set.is_valid():
        _rd.free_rid(_mpm_init_uniform_set)
    if _mpm_p2g_uniform_set_a.is_valid():
        _rd.free_rid(_mpm_p2g_uniform_set_a)
    if _mpm_p2g_uniform_set_b.is_valid():
        _rd.free_rid(_mpm_p2g_uniform_set_b)
    if _mpm_grid_uniform_set.is_valid():
        _rd.free_rid(_mpm_grid_uniform_set)
    if _mpm_g2p_uniform_set_ab.is_valid():
        _rd.free_rid(_mpm_g2p_uniform_set_ab)
    if _mpm_g2p_uniform_set_ba.is_valid():
        _rd.free_rid(_mpm_g2p_uniform_set_ba)
    if _mpm_grid_to_atlas_uniform_set_a.is_valid():
        _rd.free_rid(_mpm_grid_to_atlas_uniform_set_a)
    if _mpm_grid_to_atlas_uniform_set_b.is_valid():
        _rd.free_rid(_mpm_grid_to_atlas_uniform_set_b)
    if _mpm_particles_to_atlas_uniform_set_a.is_valid():
        _rd.free_rid(_mpm_particles_to_atlas_uniform_set_a)
    if _mpm_particles_to_atlas_uniform_set_b.is_valid():
        _rd.free_rid(_mpm_particles_to_atlas_uniform_set_b)
    if _mpm_rigid_map_set_a.is_valid():
        _rd.free_rid(_mpm_rigid_map_set_a)
    if _mpm_rigid_map_set_b.is_valid():
        _rd.free_rid(_mpm_rigid_map_set_b)
    if _mpm_update_bonds_set_a.is_valid():
        _rd.free_rid(_mpm_update_bonds_set_a)
    if _mpm_update_bonds_set_b.is_valid():
        _rd.free_rid(_mpm_update_bonds_set_b)
    if _mpm_ccl_init_set_a.is_valid():
        _rd.free_rid(_mpm_ccl_init_set_a)
    if _mpm_ccl_init_set_b.is_valid():
        _rd.free_rid(_mpm_ccl_init_set_b)
    if _mpm_ccl_prop_set_a_ab.is_valid():
        _rd.free_rid(_mpm_ccl_prop_set_a_ab)
    if _mpm_ccl_prop_set_a_ba.is_valid():
        _rd.free_rid(_mpm_ccl_prop_set_a_ba)
    if _mpm_ccl_prop_set_b_ab.is_valid():
        _rd.free_rid(_mpm_ccl_prop_set_b_ab)
    if _mpm_ccl_prop_set_b_ba.is_valid():
        _rd.free_rid(_mpm_ccl_prop_set_b_ba)
    if _mpm_ccl_write_set_a.is_valid():
        _rd.free_rid(_mpm_ccl_write_set_a)
    if _mpm_ccl_write_set_b.is_valid():
        _rd.free_rid(_mpm_ccl_write_set_b)
    if _mpm_island_accum0_set_a.is_valid():
        _rd.free_rid(_mpm_island_accum0_set_a)
    if _mpm_island_accum0_set_b.is_valid():
        _rd.free_rid(_mpm_island_accum0_set_b)
    if _mpm_island_finalize_set.is_valid():
        _rd.free_rid(_mpm_island_finalize_set)
    if _mpm_island_accum1_set_a.is_valid():
        _rd.free_rid(_mpm_island_accum1_set_a)
    if _mpm_island_accum1_set_b.is_valid():
        _rd.free_rid(_mpm_island_accum1_set_b)
    if _mpm_island_apply_set_a.is_valid():
        _rd.free_rid(_mpm_island_apply_set_a)
    if _mpm_island_apply_set_b.is_valid():
        _rd.free_rid(_mpm_island_apply_set_b)
    if _mpm_stats_init_set.is_valid():
        _rd.free_rid(_mpm_stats_init_set)
    if _mpm_stats_set_a.is_valid():
        _rd.free_rid(_mpm_stats_set_a)
    if _mpm_stats_set_b.is_valid():
        _rd.free_rid(_mpm_stats_set_b)
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
    if _atlas_static_rid.is_valid():
        _rd.free_rid(_atlas_static_rid)
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
    if _mpm_stats_rid.is_valid():
        _rd.free_rid(_mpm_stats_rid)
    if _active_list_rid.is_valid():
        _rd.free_rid(_active_list_rid)
    if _active_count_rid.is_valid():
        _rd.free_rid(_active_count_rid)
    if _sim_dispatch_rid.is_valid():
        _rd.free_rid(_sim_dispatch_rid)
    if _material_props_rid.is_valid():
        _rd.free_rid(_material_props_rid)
    if _mpm_pos_mass_a_rid.is_valid():
        _rd.free_rid(_mpm_pos_mass_a_rid)
    if _mpm_pos_mass_b_rid.is_valid():
        _rd.free_rid(_mpm_pos_mass_b_rid)
    if _mpm_vel_vol_a_rid.is_valid():
        _rd.free_rid(_mpm_vel_vol_a_rid)
    if _mpm_vel_vol_b_rid.is_valid():
        _rd.free_rid(_mpm_vel_vol_b_rid)
    if _mpm_c_a_rid.is_valid():
        _rd.free_rid(_mpm_c_a_rid)
    if _mpm_c_b_rid.is_valid():
        _rd.free_rid(_mpm_c_b_rid)
    if _mpm_f_a_rid.is_valid():
        _rd.free_rid(_mpm_f_a_rid)
    if _mpm_f_b_rid.is_valid():
        _rd.free_rid(_mpm_f_b_rid)
    if _mpm_meta_rid.is_valid():
        _rd.free_rid(_mpm_meta_rid)
    if _mpm_particle_count_rid.is_valid():
        _rd.free_rid(_mpm_particle_count_rid)
    if _mpm_grid_accum_rid.is_valid():
        _rd.free_rid(_mpm_grid_accum_rid)
    if _mpm_grid_vel_rid.is_valid():
        _rd.free_rid(_mpm_grid_vel_rid)
    if _mpm_rigid_map_rid.is_valid():
        _rd.free_rid(_mpm_rigid_map_rid)
    if _mpm_cell_pos_rid.is_valid():
        _rd.free_rid(_mpm_cell_pos_rid)
    if _mpm_labels_a_rid.is_valid():
        _rd.free_rid(_mpm_labels_a_rid)
    if _mpm_labels_b_rid.is_valid():
        _rd.free_rid(_mpm_labels_b_rid)
    if _mpm_island_mass_mom_rid.is_valid():
        _rd.free_rid(_mpm_island_mass_mom_rid)
    if _mpm_island_mass_com_rid.is_valid():
        _rd.free_rid(_mpm_island_mass_com_rid)
    if _mpm_island_com_mass_rid.is_valid():
        _rd.free_rid(_mpm_island_com_mass_rid)
    if _mpm_island_vel_rid.is_valid():
        _rd.free_rid(_mpm_island_vel_rid)
    if _mpm_island_L_rid.is_valid():
        _rd.free_rid(_mpm_island_L_rid)
    if _mpm_island_I0_rid.is_valid():
        _rd.free_rid(_mpm_island_I0_rid)
    if _mpm_island_I1_rid.is_valid():
        _rd.free_rid(_mpm_island_I1_rid)
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
    if _mpm_copy_static_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_copy_static_pipeline_rid)
    if _mpm_copy_static_shader_rid.is_valid():
        _rd.free_rid(_mpm_copy_static_shader_rid)
    if _mpm_init_particles_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_init_particles_pipeline_rid)
    if _mpm_init_particles_shader_rid.is_valid():
        _rd.free_rid(_mpm_init_particles_shader_rid)
    if _mpm_p2g_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_p2g_pipeline_rid)
    if _mpm_p2g_shader_rid.is_valid():
        _rd.free_rid(_mpm_p2g_shader_rid)
    if _mpm_grid_update_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_grid_update_pipeline_rid)
    if _mpm_grid_update_shader_rid.is_valid():
        _rd.free_rid(_mpm_grid_update_shader_rid)
    if _mpm_g2p_advect_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_g2p_advect_pipeline_rid)
    if _mpm_g2p_advect_shader_rid.is_valid():
        _rd.free_rid(_mpm_g2p_advect_shader_rid)
    if _mpm_grid_to_atlas_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_grid_to_atlas_pipeline_rid)
    if _mpm_grid_to_atlas_shader_rid.is_valid():
        _rd.free_rid(_mpm_grid_to_atlas_shader_rid)
    if _mpm_particles_to_atlas_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_particles_to_atlas_pipeline_rid)
    if _mpm_particles_to_atlas_shader_rid.is_valid():
        _rd.free_rid(_mpm_particles_to_atlas_shader_rid)
    if _mpm_build_rigid_map_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_build_rigid_map_pipeline_rid)
    if _mpm_build_rigid_map_shader_rid.is_valid():
        _rd.free_rid(_mpm_build_rigid_map_shader_rid)
    if _mpm_update_bonds_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_update_bonds_pipeline_rid)
    if _mpm_update_bonds_shader_rid.is_valid():
        _rd.free_rid(_mpm_update_bonds_shader_rid)
    if _mpm_ccl_init_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_ccl_init_pipeline_rid)
    if _mpm_ccl_init_shader_rid.is_valid():
        _rd.free_rid(_mpm_ccl_init_shader_rid)
    if _mpm_ccl_propagate_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_ccl_propagate_pipeline_rid)
    if _mpm_ccl_propagate_shader_rid.is_valid():
        _rd.free_rid(_mpm_ccl_propagate_shader_rid)
    if _mpm_ccl_write_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_ccl_write_pipeline_rid)
    if _mpm_ccl_write_shader_rid.is_valid():
        _rd.free_rid(_mpm_ccl_write_shader_rid)
    if _mpm_island_accum0_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_island_accum0_pipeline_rid)
    if _mpm_island_accum0_shader_rid.is_valid():
        _rd.free_rid(_mpm_island_accum0_shader_rid)
    if _mpm_island_finalize_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_island_finalize_pipeline_rid)
    if _mpm_island_finalize_shader_rid.is_valid():
        _rd.free_rid(_mpm_island_finalize_shader_rid)
    if _mpm_island_accum1_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_island_accum1_pipeline_rid)
    if _mpm_island_accum1_shader_rid.is_valid():
        _rd.free_rid(_mpm_island_accum1_shader_rid)
    if _mpm_island_apply_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_island_apply_pipeline_rid)
    if _mpm_island_apply_shader_rid.is_valid():
        _rd.free_rid(_mpm_island_apply_shader_rid)
    if _mpm_stats_init_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_stats_init_pipeline_rid)
    if _mpm_stats_init_shader_rid.is_valid():
        _rd.free_rid(_mpm_stats_init_shader_rid)
    if _mpm_stats_pipeline_rid.is_valid():
        _rd.free_rid(_mpm_stats_pipeline_rid)
    if _mpm_stats_shader_rid.is_valid():
        _rd.free_rid(_mpm_stats_shader_rid)
