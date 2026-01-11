#pragma once

#include "core/math/vector3.h"
#include "core/math/vector3i.h"
#include "core/templates/rid.h"
#include "core/string/node_path.h"
#include "core/templates/vector.h"
#include "core/variant/array.h"
#include "core/variant/variant.h"
#include "scene/main/node.h"

class RenderingDevice;
class Camera3D;
class MeshInstance3D;
class ShaderMaterial;
class Texture2DRD;

class VoxelRenderer : public Node {
    GDCLASS(VoxelRenderer, Node);

    NodePath quad_path;
    NodePath camera_path;
    int width = 512;
    int height = 512;
    int chunk_size = 8;
    int chunk_grid = 3;
    float lattice_spacing = 1.0f;
    float max_distance = 200.0f;
    bool auto_max_distance = true;
    float fill_radius_ratio = 0.35f;
    int fill_mode = 0;
    float noise_threshold = 0.55f;
    String voxel_data_path = "res://data/voxels.json";
    Vector3 gravity_dir = Vector3(0.0f, -1.0f, 0.0f);
    Vector3 world_rotation = Vector3();
    bool light_enabled = true;
    int light_every = 1;
    int metrics_every = 30;
    bool debug_logging = false;
    int debug_log_every = 60;
    bool debug_render_thread_ping = false;
    bool debug_probe_enabled = false;
    Vector3i debug_probe_cell = Vector3i();
    int debug_probe_every = 60;
    bool sim_enabled = false;
    int sim_every = 1;
    bool sim_clear_output = true;

    RenderingDevice *_rd = nullptr;
    RID _shader_rid;
    RID _pipeline_rid;
    RID _occupancy_shader_rid;
    RID _occupancy_pipeline_rid;
    RID _sim_shader_rid;
    RID _sim_pipeline_rid;
    RID _light_shader_rid;
    RID _light_pipeline_rid;
    RID _active_list_shader_rid;
    RID _active_list_pipeline_rid;
    RID _active_dispatch_shader_rid;
    RID _active_dispatch_pipeline_rid;
    RID _texture_rid;
    RID _ubo_rid;
    RID _indirection_rid;
    RID _atlas_a_rid;
    RID _atlas_b_rid;
        RID _light_a_rid;
        RID _light_b_rid;
        RID _occupancy_rid;
        RID _metrics_rid;
        RID _active_list_rid;
        RID _active_count_rid;
        RID _sim_dispatch_rid;
        RID _uniform_set_a_light_a_rid;
        RID _uniform_set_a_light_b_rid;
        RID _uniform_set_b_light_a_rid;
        RID _uniform_set_b_light_b_rid;
        RID _occupancy_uniform_set_a_rid;
        RID _occupancy_uniform_set_b_rid;
        RID _sim_uniform_set_ab;
        RID _sim_uniform_set_ba;
        RID _active_list_uniform_set_rid;
        RID _active_dispatch_uniform_set_rid;
        RID _light_uniform_set_a_ab;
        RID _light_uniform_set_a_ba;
        RID _light_uniform_set_b_ab;
        RID _light_uniform_set_b_ba;

	int _occupancy_bytes = 0;
	int _metrics_bytes = 0;
	int _atlas_bytes = 0;
	int _active_list_bytes = 0;
	int _active_count_bytes = 0;
    int _sim_dispatch_bytes = 0;

    Ref<Texture2DRD> _display_texture;
    Ref<ShaderMaterial> _display_material;
    Camera3D *_camera = nullptr;
	bool _render_ready = false;
	bool _use_global_rd = false;
	int _metrics_frame = 0;
	int _debug_frame = 0;
	int _debug_probe_frame = 0;
	int _sim_frame = 0;
	bool _atlas_use_a = true;
	bool _light_use_a = true;
	int _light_frame = 0;
	bool _active_list_ready = false;
	// Tracks current image RID used by raymarch uniform sets; rebuild if RS reassigns.
	RID _raymarch_img_rid;
	PackedInt32Array _indirection_cpu;

	void _init_render_resources();
	void _create_display_material(MeshInstance3D *p_quad);
	Ref<Texture2DRD> _create_display_texture();
    void _ensure_display_texture();
	void _dispatch_compute();
	void _dispatch_sim(int p_grid_extent);
	void _dispatch_occupancy();
	void _dispatch_active_list();
	void _dispatch_active_dispatch();
	void _dispatch_light(int p_grid_extent);
	void _reset_metrics();
	void _readback_metrics();
	void _readback_metrics_on_render_thread();
	void _rebuild_raymarch_uniform_sets();
	void _debug_dump_buffers_on_render_thread();
	void _debug_log_snapshot(const Vector3 &p_pos, const Basis &p_basis, float p_world_extent);
	void _debug_render_thread_ping(int p_frame_id);
	void _debug_request_probe();
	void _debug_probe_readback_on_render_thread(int p_frame_id, const Vector3i &p_cell, bool p_parity, int p_ind, int p_atlas_index, int p_atlas_offset, int p_occ_offset, RID p_atlas_rid);
	void _update_params(const PackedByteArray &p_bytes);
    Vector3 _normalized_gravity() const;
    void _prime_active_list();
    void _upload_brickmap_data();
    Array _load_voxel_entries(int p_grid_extent) const;
    bool _bcc_parity(const Vector3i &p_cell) const;
    RID _current_atlas_rid() const;
    RID _current_raymarch_uniform_set() const;
    RID _current_light_uniform_set() const;
    void _free_render_resources();

protected:
    static void _bind_methods();
    void _notification(int p_what);
    void _process(double p_delta);

public:
    void set_quad_path(const NodePath &p_path);
    NodePath get_quad_path() const;

    void set_camera_path(const NodePath &p_path);
    NodePath get_camera_path() const;

    void set_width(int p_width);
    int get_width() const;

    void set_height(int p_height);
    int get_height() const;

    void set_chunk_size(int p_chunk_size);
    int get_chunk_size() const;

    void set_chunk_grid(int p_chunk_grid);
    int get_chunk_grid() const;

    void set_lattice_spacing(float p_spacing);
    float get_lattice_spacing() const;

    void set_max_distance(float p_distance);
    float get_max_distance() const;

    void set_auto_max_distance(bool p_enabled);
    bool is_auto_max_distance() const;

    void set_fill_radius_ratio(float p_ratio);
    float get_fill_radius_ratio() const;

    void set_fill_mode(int p_mode);
    int get_fill_mode() const;

    void set_noise_threshold(float p_threshold);
    float get_noise_threshold() const;

    void set_voxel_data_path(const String &p_path);
    String get_voxel_data_path() const;

    void set_gravity_dir(const Vector3 &p_gravity);
    Vector3 get_gravity_dir() const;

    void set_world_rotation(const Vector3 &p_rotation);
    Vector3 get_world_rotation() const;

    void set_light_enabled(bool p_enabled);
    bool is_light_enabled() const;

    void set_light_every(int p_every);
    int get_light_every() const;

    void set_metrics_every(int p_every);
    int get_metrics_every() const;

    void set_debug_logging(bool p_enabled);
    bool is_debug_logging() const;

    void set_debug_log_every(int p_every);
    int get_debug_log_every() const;

    void set_debug_render_thread_ping(bool p_enabled);
    bool is_debug_render_thread_ping() const;

    void set_debug_probe_enabled(bool p_enabled);
    bool is_debug_probe_enabled() const;

    void set_debug_probe_cell(const Vector3i &p_cell);
    Vector3i get_debug_probe_cell() const;

    void set_debug_probe_every(int p_every);
    int get_debug_probe_every() const;

    void set_sim_enabled(bool p_enabled);
    bool is_sim_enabled() const;

    void set_sim_every(int p_every);
    int get_sim_every() const;

	void set_sim_clear_output(bool p_clear);
	bool is_sim_clear_output() const;

	Dictionary get_render_debug_state() const;
	void debug_rebind_display_texture();
	void debug_dump_buffers();
	void debug_log_state() const;
	String debug_peek_buffers() const;
	Dictionary debug_peek_metrics() const;

	void set_voxel_entries(const Array &p_entries, bool p_allocate_all_bricks = false);
	void set_debug_probe_cell_xyz(int p_x, int p_y, int p_z);
	bool is_render_ready() const;

    VoxelRenderer();
    ~VoxelRenderer();
};
