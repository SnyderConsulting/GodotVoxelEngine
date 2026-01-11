#include "voxel_renderer.h"

#include "core/io/file_access.h"
#include "core/io/json.h"
#include "core/io/resource_loader.h"
#include "core/math/math_funcs.h"
#include "core/object/class_db.h"
#include "core/object/callable_method_pointer.h"
#include "core/os/thread.h"
#include "core/string/print_string.h"
#include "core/string/ustring.h"
#include "core/variant/variant.h"
#include "scene/3d/camera_3d.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/resources/mesh.h"
#include "scene/resources/shader.h"
#include "scene/resources/material.h"
#include "scene/resources/texture_rd.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_device_binds.h"
#include "servers/rendering/rendering_server.h"

#include "compute_active_dispatch.glsl.gen.h"
#include "compute_active_list.glsl.gen.h"
#include "compute_light.glsl.gen.h"
#include "compute_occupancy.glsl.gen.h"
#include "compute_raymarch.glsl.gen.h"
#include "compute_sim.glsl.gen.h"

#include <cstdint>
#include <cstring>

static Ref<RDShaderFile> _parse_compute_shader(const char *p_source, const String &p_name) {
	Ref<RDShaderFile> shader_file;
	shader_file.instantiate();
	Error err = shader_file->parse_versions_from_text(String(p_source));
	if (err != OK) {
		shader_file->print_errors(p_name);
		return Ref<RDShaderFile>();
	}
	return shader_file;
}

VoxelRenderer::VoxelRenderer() {
	set_process(true);
}

VoxelRenderer::~VoxelRenderer() {
	_free_render_resources();
}

void VoxelRenderer::_notification(int p_what) {
        if (p_what == NOTIFICATION_PROCESS) {
                _process(get_process_delta_time());
                return;
        }
        if (p_what == NOTIFICATION_READY) {
                _rd = RenderingServer::get_singleton()->get_rendering_device();
                _use_global_rd = _rd != nullptr;
                if (_rd == nullptr) {
                        ERR_FAIL_MSG("RenderingDevice unavailable.");
                }
                if (!_use_global_rd) {
                        ERR_FAIL_MSG("Pure GPU path requires the global RenderingDevice.");
                }
                set_process(true);

                MeshInstance3D *quad = Object::cast_to<MeshInstance3D>(get_node_or_null(quad_path));
		if (quad == nullptr) {
			ERR_FAIL_MSG("VoxelRenderer quad_path missing or invalid.");
		}
		_camera = Object::cast_to<Camera3D>(get_node_or_null(camera_path));
		if (_camera == nullptr) {
			ERR_FAIL_MSG("VoxelRenderer camera_path missing or invalid.");
		}

		_create_display_material(quad);
		_init_render_resources();
        } else if (p_what == NOTIFICATION_EXIT_TREE) {
                _free_render_resources();
        }
        Node::_notification(p_what);
}

void VoxelRenderer::_create_display_material(MeshInstance3D *p_quad) {
    Ref<ShaderMaterial> existing = p_quad->get_material_override();
    if (existing.is_valid()) {
        _display_material = existing;
    } else {
		_display_material.instantiate();
		p_quad->set_material_override(_display_material);
	}

    if (_display_material->get_shader().is_valid()) {
        return;
    }

    Ref<Shader> shader = ResourceLoader::load("res://shaders/compute_display.gdshader");
    if (shader.is_valid()) {
        _display_material->set_shader(shader);
        return;
    }

    Ref<Shader> fallback;
    fallback.instantiate();
    fallback->set_code(
                    "shader_type spatial;\n"
                    "render_mode unshaded, cull_disabled, depth_draw_never;\n"
                    "uniform sampler2D compute_tex;\n"
                    "void fragment() {\n"
                    "    vec3 color = texture(compute_tex, UV).rgb;\n"
                    "    ALBEDO = color;\n"
                    "}\n");
    _display_material->set_shader(fallback);
}

Ref<Texture2DRD> VoxelRenderer::_create_display_texture() {
    if (_use_global_rd && ClassDB::class_exists("Texture2DRD")) {
        Ref<Texture2DRD> tex;
        tex.instantiate();
        tex->set_texture_rd_rid(_texture_rid);
        return tex;
    }
    return Ref<Texture2DRD>();
}

void VoxelRenderer::_ensure_display_texture() {
    if (_display_texture.is_null() || _display_material.is_null()) {
        return;
    }
    Ref<Texture2DRD> tex_rd = _display_texture;
    if (tex_rd.is_null()) {
        return;
    }

    RID rs_rid = tex_rd->get_rid();
    RID rs_rd = RenderingServer::get_singleton()->texture_get_rd_texture(rs_rid);
    RID tex_rd_rid = tex_rd->get_texture_rd_rid();
    bool needs_rebuild = false;
    if (_texture_rid.is_valid() && (!rs_rd.is_valid() || rs_rd != _texture_rid)) {
        // RS thinks this Texture2D is backed by a different RD texture; follow RS so sampling and compute stay in sync.
        if (debug_logging) {
            print_line(vformat("VoxelRenderer ensure_display_texture | RS RD mismatch | rs_rd=%d compute_rid=%d tex_rd_rid=%d",
                    rs_rd.get_id(),
                    _texture_rid.get_id(),
                    tex_rd_rid.get_id()));
        }
        if (rs_rd.is_valid()) {
            _texture_rid = rs_rd;
            needs_rebuild = true;
        } else {
            tex_rd->set_texture_rd_rid(_texture_rid);
        }
    }
    if (debug_logging && rs_rd.is_valid() && tex_rd_rid != rs_rd) {
        print_line(vformat("VoxelRenderer ensure_display_texture | tex_rd_rid mismatch | rs_rd=%d tex_rd_rid=%d",
                rs_rd.get_id(),
                tex_rd_rid.get_id()));
    }
    if (needs_rebuild) {
        _rebuild_raymarch_uniform_sets();
    }

    Variant compute_tex = _display_material->get_shader_parameter("compute_tex");
    bool needs_bind = compute_tex.get_type() != Variant::OBJECT;
    if (!needs_bind) {
        Object *obj = compute_tex;
        if (obj == nullptr || Object::cast_to<Texture2D>(obj) == nullptr) {
            needs_bind = true;
        }
    }
    if (needs_bind) {
        _display_material->set_shader_parameter("compute_tex", _display_texture);
    }
}

void VoxelRenderer::_init_render_resources() {
        if (_rd == nullptr) {
                return;
        }

        print_line("VoxelRenderer init | build_tag=voxels-rsrd-sync-20260107b");

	Ref<RDShaderFile> raymarch_shader = _parse_compute_shader(compute_raymarch_shader_glsl, "compute_raymarch.glsl");
	if (raymarch_shader.is_null()) {
		ERR_FAIL_MSG("Missing compute shader source: compute_raymarch.glsl");
	}
	_shader_rid = _rd->shader_create_from_spirv(raymarch_shader->get_spirv_stages());
	if (!_shader_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create compute shader.");
	}
        _pipeline_rid = _rd->compute_pipeline_create(_shader_rid);
        if (!_pipeline_rid.is_valid()) {
                ERR_FAIL_MSG("Failed to create compute pipeline.");
        }

        Ref<RDShaderFile> occ_shader = _parse_compute_shader(compute_occupancy_shader_glsl, "compute_occupancy.glsl");
        if (!occ_shader.is_null()) {
                _occupancy_shader_rid = _rd->shader_create_from_spirv(occ_shader->get_spirv_stages());
                if (_occupancy_shader_rid.is_valid()) {
                        _occupancy_pipeline_rid = _rd->compute_pipeline_create(_occupancy_shader_rid);
		}
	}

	Ref<RDShaderFile> sim_shader = _parse_compute_shader(compute_sim_shader_glsl, "compute_sim.glsl");
	if (!sim_shader.is_null()) {
		_sim_shader_rid = _rd->shader_create_from_spirv(sim_shader->get_spirv_stages());
		if (_sim_shader_rid.is_valid()) {
			_sim_pipeline_rid = _rd->compute_pipeline_create(_sim_shader_rid);
		}
	}

	Ref<RDShaderFile> light_shader = _parse_compute_shader(compute_light_shader_glsl, "compute_light.glsl");
	if (!light_shader.is_null()) {
		_light_shader_rid = _rd->shader_create_from_spirv(light_shader->get_spirv_stages());
		if (_light_shader_rid.is_valid()) {
			_light_pipeline_rid = _rd->compute_pipeline_create(_light_shader_rid);
		}
	}

	Ref<RDShaderFile> active_list_shader = _parse_compute_shader(compute_active_list_shader_glsl, "compute_active_list.glsl");
	if (!active_list_shader.is_null()) {
		_active_list_shader_rid = _rd->shader_create_from_spirv(active_list_shader->get_spirv_stages());
		if (_active_list_shader_rid.is_valid()) {
			_active_list_pipeline_rid = _rd->compute_pipeline_create(_active_list_shader_rid);
		}
	}

	Ref<RDShaderFile> active_dispatch_shader = _parse_compute_shader(compute_active_dispatch_shader_glsl, "compute_active_dispatch.glsl");
	if (!active_dispatch_shader.is_null()) {
		_active_dispatch_shader_rid = _rd->shader_create_from_spirv(active_dispatch_shader->get_spirv_stages());
		if (_active_dispatch_shader_rid.is_valid()) {
			_active_dispatch_pipeline_rid = _rd->compute_pipeline_create(_active_dispatch_shader_rid);
		}
	}

	RD::TextureFormat fmt;
	fmt.width = width;
	fmt.height = height;
	fmt.depth = 1;
	fmt.format = RD::DATA_FORMAT_R8G8B8A8_UNORM;
	fmt.usage_bits = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;

        RD::TextureView view;
        _texture_rid = _rd->texture_create(fmt, view, Vector<Vector<uint8_t>>());
        if (!_texture_rid.is_valid()) {
                ERR_FAIL_MSG("Failed to create compute texture.");
        }

    // Create the display texture now that _texture_rid exists and bind it
    _display_texture = _create_display_texture();
    if (_display_texture.is_null()) {
        ERR_FAIL_MSG("Failed to create GPU display texture.");
    }
    RID rs_rd = RenderingServer::get_singleton()->texture_get_rd_texture(_display_texture->get_rid());
    if (rs_rd.is_valid() && (!_texture_rid.is_valid() || rs_rd != _texture_rid)) {
        _texture_rid = rs_rd;
    }
    _display_material->set_shader_parameter("compute_tex", _display_texture);
    _raymarch_img_rid = _texture_rid;
    print_line(vformat("VoxelRenderer init | texture_rid=%d display_rd=%d rs_rd=%d",
            _texture_rid.get_id(),
            _display_texture->get_texture_rd_rid().get_id(),
            rs_rd.get_id()));

        _ubo_rid = _rd->uniform_buffer_create(208);
        if (!_ubo_rid.is_valid()) {
                ERR_FAIL_MSG("Failed to create uniform buffer.");
        }

	int brick_grid = chunk_grid;
	int brick_count = brick_grid * brick_grid * brick_grid;
	int indirection_bytes = brick_count * 4;
	_atlas_bytes = brick_count * chunk_size * chunk_size * chunk_size * 4;
	int occupancy_bytes = brick_count * 4;
	_occupancy_bytes = occupancy_bytes;
	_metrics_bytes = 16;

	_indirection_rid = _rd->storage_buffer_create(indirection_bytes);
	if (!_indirection_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create indirection buffer.");
	}
	_atlas_a_rid = _rd->storage_buffer_create(_atlas_bytes);
	if (!_atlas_a_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create atlas buffer A.");
	}
	_atlas_b_rid = _rd->storage_buffer_create(_atlas_bytes);
	if (!_atlas_b_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create atlas buffer B.");
	}
	_light_a_rid = _rd->storage_buffer_create(_atlas_bytes);
	if (!_light_a_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create light buffer A.");
	}
	_light_b_rid = _rd->storage_buffer_create(_atlas_bytes);
	if (!_light_b_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create light buffer B.");
	}
	_occupancy_rid = _rd->storage_buffer_create(occupancy_bytes);
	if (!_occupancy_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create occupancy buffer.");
	}
        _metrics_rid = _rd->storage_buffer_create(_metrics_bytes);
        if (!_metrics_rid.is_valid()) {
                ERR_FAIL_MSG("Failed to create metrics buffer.");
        }

        _active_list_bytes = brick_count * 4;
        _active_count_bytes = 4;
        _sim_dispatch_bytes = 16;
        _active_list_rid = _rd->storage_buffer_create(_active_list_bytes);
        if (!_active_list_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create active list buffer.");
	}
	_active_count_rid = _rd->storage_buffer_create(_active_count_bytes);
	if (!_active_count_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create active count buffer.");
	}

	PackedInt32Array dispatch_init;
	dispatch_init.resize(4);
	dispatch_init.set(0, 0);
	dispatch_init.set(1, 1);
	dispatch_init.set(2, 1);
	dispatch_init.set(3, 0);
	PackedByteArray dispatch_bytes = dispatch_init.to_byte_array();
	_sim_dispatch_rid = _rd->storage_buffer_create(_sim_dispatch_bytes, dispatch_bytes, RenderingDevice::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
	if (!_sim_dispatch_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create sim dispatch buffer.");
	}

	_upload_brickmap_data();
	if (_light_a_rid.is_valid()) {
		_rd->buffer_clear(_light_a_rid, 0, _atlas_bytes);
	}
	if (_light_b_rid.is_valid()) {
		_rd->buffer_clear(_light_b_rid, 0, _atlas_bytes);
	}

	RD::Uniform img_uniform;
	img_uniform.uniform_type = RD::UNIFORM_TYPE_IMAGE;
	img_uniform.binding = 0;
	img_uniform.append_id(_texture_rid);

	RD::Uniform ubo_uniform;
	ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
	ubo_uniform.binding = 1;
	ubo_uniform.append_id(_ubo_rid);

	RD::Uniform indirection_uniform;
	indirection_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	indirection_uniform.binding = 2;
	indirection_uniform.append_id(_indirection_rid);

	RD::Uniform atlas_uniform_a;
	atlas_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	atlas_uniform_a.binding = 3;
	atlas_uniform_a.append_id(_atlas_a_rid);

	RD::Uniform atlas_uniform_b;
	atlas_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	atlas_uniform_b.binding = 3;
	atlas_uniform_b.append_id(_atlas_b_rid);

	RD::Uniform occupancy_uniform;
	occupancy_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occupancy_uniform.binding = 4;
	occupancy_uniform.append_id(_occupancy_rid);

	RD::Uniform metrics_uniform;
	metrics_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        metrics_uniform.binding = 5;
        metrics_uniform.append_id(_metrics_rid);

        RD::Uniform light_uniform_a;
        light_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        light_uniform_a.binding = 6;
        light_uniform_a.append_id(_light_a_rid);

	RD::Uniform light_uniform_b;
	light_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	light_uniform_b.binding = 6;
	light_uniform_b.append_id(_light_b_rid);

        Vector<RD::Uniform> ray_uniforms_a_light_a;
        ray_uniforms_a_light_a.push_back(img_uniform);
        ray_uniforms_a_light_a.push_back(ubo_uniform);
        ray_uniforms_a_light_a.push_back(indirection_uniform);
        ray_uniforms_a_light_a.push_back(atlas_uniform_a);
        ray_uniforms_a_light_a.push_back(occupancy_uniform);
        ray_uniforms_a_light_a.push_back(metrics_uniform);
        ray_uniforms_a_light_a.push_back(light_uniform_a);
        _uniform_set_a_light_a_rid = _rd->uniform_set_create(ray_uniforms_a_light_a, _shader_rid, 0);
	if (!_uniform_set_a_light_a_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create uniform set A (light A).");
	}
        Vector<RD::Uniform> ray_uniforms_a_light_b;
        ray_uniforms_a_light_b.push_back(img_uniform);
        ray_uniforms_a_light_b.push_back(ubo_uniform);
        ray_uniforms_a_light_b.push_back(indirection_uniform);
        ray_uniforms_a_light_b.push_back(atlas_uniform_a);
        ray_uniforms_a_light_b.push_back(occupancy_uniform);
        ray_uniforms_a_light_b.push_back(metrics_uniform);
        ray_uniforms_a_light_b.push_back(light_uniform_b);
        _uniform_set_a_light_b_rid = _rd->uniform_set_create(ray_uniforms_a_light_b, _shader_rid, 0);
	if (!_uniform_set_a_light_b_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create uniform set A (light B).");
	}
        Vector<RD::Uniform> ray_uniforms_b_light_a;
        ray_uniforms_b_light_a.push_back(img_uniform);
        ray_uniforms_b_light_a.push_back(ubo_uniform);
        ray_uniforms_b_light_a.push_back(indirection_uniform);
        ray_uniforms_b_light_a.push_back(atlas_uniform_b);
        ray_uniforms_b_light_a.push_back(occupancy_uniform);
        ray_uniforms_b_light_a.push_back(metrics_uniform);
        ray_uniforms_b_light_a.push_back(light_uniform_a);
        _uniform_set_b_light_a_rid = _rd->uniform_set_create(ray_uniforms_b_light_a, _shader_rid, 0);
	if (!_uniform_set_b_light_a_rid.is_valid()) {
		ERR_FAIL_MSG("Failed to create uniform set B (light A).");
	}
        Vector<RD::Uniform> ray_uniforms_b_light_b;
        ray_uniforms_b_light_b.push_back(img_uniform);
        ray_uniforms_b_light_b.push_back(ubo_uniform);
        ray_uniforms_b_light_b.push_back(indirection_uniform);
        ray_uniforms_b_light_b.push_back(atlas_uniform_b);
        ray_uniforms_b_light_b.push_back(occupancy_uniform);
        ray_uniforms_b_light_b.push_back(metrics_uniform);
        ray_uniforms_b_light_b.push_back(light_uniform_b);
        _uniform_set_b_light_b_rid = _rd->uniform_set_create(ray_uniforms_b_light_b, _shader_rid, 0);
        if (!_uniform_set_b_light_b_rid.is_valid()) {
                ERR_FAIL_MSG("Failed to create uniform set B (light B).");
        }

        RD::Uniform occ_ubo_uniform;
        occ_ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
        occ_ubo_uniform.binding = 0;
        occ_ubo_uniform.append_id(_ubo_rid);

	RD::Uniform occ_indirection_uniform;
	occ_indirection_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occ_indirection_uniform.binding = 1;
	occ_indirection_uniform.append_id(_indirection_rid);

	RD::Uniform occ_atlas_uniform_a;
	occ_atlas_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occ_atlas_uniform_a.binding = 2;
	occ_atlas_uniform_a.append_id(_atlas_a_rid);

	RD::Uniform occ_atlas_uniform_b;
	occ_atlas_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occ_atlas_uniform_b.binding = 2;
	occ_atlas_uniform_b.append_id(_atlas_b_rid);

	RD::Uniform occ_out_uniform;
	occ_out_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occ_out_uniform.binding = 3;
	occ_out_uniform.append_id(_occupancy_rid);

	RD::Uniform occ_metrics_uniform;
	occ_metrics_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
	occ_metrics_uniform.binding = 4;
	occ_metrics_uniform.append_id(_metrics_rid);

	if (_occupancy_shader_rid.is_valid()) {
        Vector<RD::Uniform> occ_uniforms_a;
        occ_uniforms_a.push_back(occ_ubo_uniform);
        occ_uniforms_a.push_back(occ_indirection_uniform);
        occ_uniforms_a.push_back(occ_atlas_uniform_a);
        occ_uniforms_a.push_back(occ_out_uniform);
        occ_uniforms_a.push_back(occ_metrics_uniform);
        _occupancy_uniform_set_a_rid = _rd->uniform_set_create(occ_uniforms_a, _occupancy_shader_rid, 0);
		if (!_occupancy_uniform_set_a_rid.is_valid()) {
			ERR_FAIL_MSG("Failed to create occupancy uniform set A.");
		}
        Vector<RD::Uniform> occ_uniforms_b;
        occ_uniforms_b.push_back(occ_ubo_uniform);
        occ_uniforms_b.push_back(occ_indirection_uniform);
        occ_uniforms_b.push_back(occ_atlas_uniform_b);
        occ_uniforms_b.push_back(occ_out_uniform);
        occ_uniforms_b.push_back(occ_metrics_uniform);
        _occupancy_uniform_set_b_rid = _rd->uniform_set_create(occ_uniforms_b, _occupancy_shader_rid, 0);
		if (!_occupancy_uniform_set_b_rid.is_valid()) {
			ERR_FAIL_MSG("Failed to create occupancy uniform set B.");
		}
	}

	if (_sim_shader_rid.is_valid()) {
		RD::Uniform sim_ubo_uniform;
		sim_ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		sim_ubo_uniform.binding = 0;
		sim_ubo_uniform.append_id(_ubo_rid);

		RD::Uniform sim_indirection_uniform;
		sim_indirection_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_indirection_uniform.binding = 1;
		sim_indirection_uniform.append_id(_indirection_rid);

		RD::Uniform sim_in_a;
		sim_in_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_in_a.binding = 2;
		sim_in_a.append_id(_atlas_a_rid);

		RD::Uniform sim_in_b;
		sim_in_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_in_b.binding = 2;
		sim_in_b.append_id(_atlas_b_rid);

		RD::Uniform sim_out_a;
		sim_out_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_out_a.binding = 3;
		sim_out_a.append_id(_atlas_a_rid);

		RD::Uniform sim_out_b;
		sim_out_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_out_b.binding = 3;
		sim_out_b.append_id(_atlas_b_rid);

		RD::Uniform sim_active_list_uniform;
		sim_active_list_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		sim_active_list_uniform.binding = 4;
		sim_active_list_uniform.append_id(_active_list_rid);

                Vector<RD::Uniform> sim_uniforms_ab;
                sim_uniforms_ab.push_back(sim_ubo_uniform);
                sim_uniforms_ab.push_back(sim_indirection_uniform);
                sim_uniforms_ab.push_back(sim_in_a);
                sim_uniforms_ab.push_back(sim_out_b);
                sim_uniforms_ab.push_back(sim_active_list_uniform);
                _sim_uniform_set_ab = _rd->uniform_set_create(sim_uniforms_ab, _sim_shader_rid, 0);
		if (!_sim_uniform_set_ab.is_valid()) {
			ERR_FAIL_MSG("Failed to create sim uniform set AB.");
		}
                Vector<RD::Uniform> sim_uniforms_ba;
                sim_uniforms_ba.push_back(sim_ubo_uniform);
                sim_uniforms_ba.push_back(sim_indirection_uniform);
                sim_uniforms_ba.push_back(sim_in_b);
                sim_uniforms_ba.push_back(sim_out_a);
                sim_uniforms_ba.push_back(sim_active_list_uniform);
                _sim_uniform_set_ba = _rd->uniform_set_create(sim_uniforms_ba, _sim_shader_rid, 0);
		if (!_sim_uniform_set_ba.is_valid()) {
			ERR_FAIL_MSG("Failed to create sim uniform set BA.");
		}
	}

	if (_active_list_shader_rid.is_valid()) {
		RD::Uniform active_ubo_uniform;
		active_ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		active_ubo_uniform.binding = 0;
		active_ubo_uniform.append_id(_ubo_rid);

		RD::Uniform active_occ_uniform;
		active_occ_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		active_occ_uniform.binding = 1;
		active_occ_uniform.append_id(_occupancy_rid);

		RD::Uniform active_list_uniform;
		active_list_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		active_list_uniform.binding = 2;
		active_list_uniform.append_id(_active_list_rid);

		RD::Uniform active_count_uniform;
		active_count_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		active_count_uniform.binding = 3;
		active_count_uniform.append_id(_active_count_rid);

		Vector<RD::Uniform> active_list_uniforms;
		active_list_uniforms.push_back(active_ubo_uniform);
		active_list_uniforms.push_back(active_occ_uniform);
		active_list_uniforms.push_back(active_list_uniform);
		active_list_uniforms.push_back(active_count_uniform);
		_active_list_uniform_set_rid = _rd->uniform_set_create(active_list_uniforms, _active_list_shader_rid, 0);
		if (!_active_list_uniform_set_rid.is_valid()) {
			ERR_FAIL_MSG("Failed to create active list uniform set.");
		}
	}

	if (_active_dispatch_shader_rid.is_valid()) {
		RD::Uniform dispatch_ubo_uniform;
		dispatch_ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		dispatch_ubo_uniform.binding = 0;
		dispatch_ubo_uniform.append_id(_ubo_rid);

		RD::Uniform active_count_uniform;
		active_count_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		active_count_uniform.binding = 1;
		active_count_uniform.append_id(_active_count_rid);

		RD::Uniform dispatch_uniform;
		dispatch_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		dispatch_uniform.binding = 2;
		dispatch_uniform.append_id(_sim_dispatch_rid);

		Vector<RD::Uniform> active_dispatch_uniforms;
		active_dispatch_uniforms.push_back(dispatch_ubo_uniform);
		active_dispatch_uniforms.push_back(active_count_uniform);
		active_dispatch_uniforms.push_back(dispatch_uniform);
		_active_dispatch_uniform_set_rid = _rd->uniform_set_create(active_dispatch_uniforms, _active_dispatch_shader_rid, 0);
		if (!_active_dispatch_uniform_set_rid.is_valid()) {
			ERR_FAIL_MSG("Failed to create active dispatch uniform set.");
		}
	}

	if (_light_shader_rid.is_valid()) {
		RD::Uniform light_ubo_uniform;
		light_ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
		light_ubo_uniform.binding = 0;
		light_ubo_uniform.append_id(_ubo_rid);

		RD::Uniform light_indirection_uniform;
		light_indirection_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_indirection_uniform.binding = 1;
		light_indirection_uniform.append_id(_indirection_rid);

		RD::Uniform light_atlas_uniform_a;
		light_atlas_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_atlas_uniform_a.binding = 2;
		light_atlas_uniform_a.append_id(_atlas_a_rid);

		RD::Uniform light_atlas_uniform_b;
		light_atlas_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_atlas_uniform_b.binding = 2;
		light_atlas_uniform_b.append_id(_atlas_b_rid);

		RD::Uniform light_in_uniform_a;
		light_in_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_in_uniform_a.binding = 3;
		light_in_uniform_a.append_id(_light_a_rid);

		RD::Uniform light_in_uniform_b;
		light_in_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_in_uniform_b.binding = 3;
		light_in_uniform_b.append_id(_light_b_rid);

		RD::Uniform light_out_uniform_a;
		light_out_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_out_uniform_a.binding = 4;
		light_out_uniform_a.append_id(_light_a_rid);

		RD::Uniform light_out_uniform_b;
		light_out_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
		light_out_uniform_b.binding = 4;
		light_out_uniform_b.append_id(_light_b_rid);

                Vector<RD::Uniform> light_uniforms_a_ab;
                light_uniforms_a_ab.push_back(light_ubo_uniform);
                light_uniforms_a_ab.push_back(light_indirection_uniform);
                light_uniforms_a_ab.push_back(light_atlas_uniform_a);
                light_uniforms_a_ab.push_back(light_in_uniform_a);
                light_uniforms_a_ab.push_back(light_out_uniform_b);
                _light_uniform_set_a_ab = _rd->uniform_set_create(light_uniforms_a_ab, _light_shader_rid, 0);
		if (!_light_uniform_set_a_ab.is_valid()) {
			ERR_FAIL_MSG("Failed to create light uniform set A AB.");
		}
                Vector<RD::Uniform> light_uniforms_a_ba;
                light_uniforms_a_ba.push_back(light_ubo_uniform);
                light_uniforms_a_ba.push_back(light_indirection_uniform);
                light_uniforms_a_ba.push_back(light_atlas_uniform_a);
                light_uniforms_a_ba.push_back(light_in_uniform_b);
                light_uniforms_a_ba.push_back(light_out_uniform_a);
                _light_uniform_set_a_ba = _rd->uniform_set_create(light_uniforms_a_ba, _light_shader_rid, 0);
		if (!_light_uniform_set_a_ba.is_valid()) {
			ERR_FAIL_MSG("Failed to create light uniform set A BA.");
		}
                Vector<RD::Uniform> light_uniforms_b_ab;
                light_uniforms_b_ab.push_back(light_ubo_uniform);
                light_uniforms_b_ab.push_back(light_indirection_uniform);
                light_uniforms_b_ab.push_back(light_atlas_uniform_b);
                light_uniforms_b_ab.push_back(light_in_uniform_a);
                light_uniforms_b_ab.push_back(light_out_uniform_b);
                _light_uniform_set_b_ab = _rd->uniform_set_create(light_uniforms_b_ab, _light_shader_rid, 0);
		if (!_light_uniform_set_b_ab.is_valid()) {
			ERR_FAIL_MSG("Failed to create light uniform set B AB.");
		}
                Vector<RD::Uniform> light_uniforms_b_ba;
                light_uniforms_b_ba.push_back(light_ubo_uniform);
                light_uniforms_b_ba.push_back(light_indirection_uniform);
                light_uniforms_b_ba.push_back(light_atlas_uniform_b);
                light_uniforms_b_ba.push_back(light_in_uniform_b);
                light_uniforms_b_ba.push_back(light_out_uniform_a);
        _light_uniform_set_b_ba = _rd->uniform_set_create(light_uniforms_b_ba, _light_shader_rid, 0);
                if (!_light_uniform_set_b_ba.is_valid()) {
                        ERR_FAIL_MSG("Failed to create light uniform set B BA.");
                }
        }
        _render_ready = true;
}

void VoxelRenderer::_free_render_resources() {
        if (_rd == nullptr) {
		return;
	}

	RID rids[] = {
		_uniform_set_a_light_a_rid,
		_uniform_set_a_light_b_rid,
		_uniform_set_b_light_a_rid,
		_uniform_set_b_light_b_rid,
		_occupancy_uniform_set_a_rid,
		_occupancy_uniform_set_b_rid,
		_sim_uniform_set_ab,
		_sim_uniform_set_ba,
		_active_list_uniform_set_rid,
		_active_dispatch_uniform_set_rid,
		_light_uniform_set_a_ab,
		_light_uniform_set_a_ba,
		_light_uniform_set_b_ab,
                _light_uniform_set_b_ba,
                _ubo_rid,
                _texture_rid,
                _indirection_rid,
                _atlas_a_rid,
                _atlas_b_rid,
                _light_a_rid,
                _light_b_rid,
                _occupancy_rid,
                _metrics_rid,
                _active_list_rid,
                _active_count_rid,
                _sim_dispatch_rid,
                _pipeline_rid,
                _shader_rid,
                _occupancy_pipeline_rid,
                _occupancy_shader_rid,
                _sim_pipeline_rid,
                _sim_shader_rid,
                _light_pipeline_rid,
                _light_shader_rid,
                _active_list_pipeline_rid,
                _active_list_shader_rid,
                _active_dispatch_pipeline_rid,
                _active_dispatch_shader_rid
        };

	for (RID rid : rids) {
		if (rid.is_valid()) {
			_rd->free_rid(rid);
		}
	}

        _render_ready = false;
}

bool VoxelRenderer::is_render_ready() const {
        return _render_ready;
}

void VoxelRenderer::_process(double p_delta) {
        (void)p_delta;
        _debug_frame += 1;
        if (debug_logging) {
                int every = debug_log_every;
                if (every < 1) {
                        every = 1;
                }
                if ((_debug_frame % every) == 0) {
                        print_line(vformat("VoxelRenderer process | frame=%d rd=%s render_ready=%s pipeline=%s camera=%s",
                                _debug_frame,
                                _rd != nullptr,
                                _render_ready,
                                _pipeline_rid.is_valid(),
                                _camera != nullptr));
                }
        }
        if (_rd == nullptr) {
                return;
        }
        if (!_render_ready || !_pipeline_rid.is_valid()) {
                return;
        }
    if (_camera == nullptr) {
        return;
    }

    _ensure_display_texture();

        Transform3D camera_transform = _camera->get_global_transform();
        Basis basis = camera_transform.basis;
        Vector3 pos = camera_transform.origin;
        float fov = Math::deg_to_rad(_camera->get_fov());
        float aspect = height > 0 ? float(width) / float(height) : 1.0f;
        float tan_half_fov = Math::tan(fov * 0.5f);
        float grid_extent = float(chunk_grid * chunk_size);
        float world_extent = grid_extent * lattice_spacing;
        float voxel_size = lattice_spacing;
        float brick_grid = float(chunk_grid);
        int grid_extent_i = chunk_grid * chunk_size;
        Basis world_basis = Basis::from_euler(world_rotation);
        Basis inv_world_basis = world_basis.inverse();
        Vector3 gravity_world = _normalized_gravity();
        Vector3 gravity = inv_world_basis.xform(gravity_world);
        Vector3 origin(-0.5f * world_extent, -0.5f * world_extent, -0.5f * world_extent);
        float effective_max_distance = max_distance;
        if (auto_max_distance) {
                Vector3 world_center = origin + Vector3(1.0f, 1.0f, 1.0f) * (0.5f * world_extent);
                float dist_to_center = pos.distance_to(world_center);
                float diag_half = Math::sqrt(3.0f) * (world_extent * 0.5f);
                float required_max = dist_to_center + diag_half + voxel_size * 4.0f;
                if (required_max > effective_max_distance) {
                        effective_max_distance = required_max;
                }
        }

        PackedFloat32Array params;
        params.resize(52);
        float *w = params.ptrw();
        int idx = 0;
        w[idx++] = grid_extent;
        w[idx++] = grid_extent;
        w[idx++] = grid_extent;
        w[idx++] = 0.0f;
        w[idx++] = origin.x;
        w[idx++] = origin.y;
        w[idx++] = origin.z;
        w[idx++] = 0.0f;
        w[idx++] = pos.x;
        w[idx++] = pos.y;
        w[idx++] = pos.z;
        w[idx++] = 0.0f;
        Vector3 basis_x = basis.get_column(0);
        Vector3 basis_y = basis.get_column(1);
        Vector3 basis_z = basis.get_column(2);
        w[idx++] = basis_x.x;
        w[idx++] = basis_x.y;
        w[idx++] = basis_x.z;
        w[idx++] = 0.0f;
        w[idx++] = basis_y.x;
        w[idx++] = basis_y.y;
        w[idx++] = basis_y.z;
        w[idx++] = 0.0f;
        Vector3 forward = -basis_z;
        w[idx++] = forward.x;
        w[idx++] = forward.y;
        w[idx++] = forward.z;
        w[idx++] = 0.0f;
        w[idx++] = float(width);
        w[idx++] = float(height);
        w[idx++] = tan_half_fov;
        w[idx++] = aspect;
        w[idx++] = voxel_size;
        w[idx++] = effective_max_distance;
        w[idx++] = 0.8f;
        w[idx++] = 0.25f;
        w[idx++] = brick_grid;
        w[idx++] = brick_grid;
        w[idx++] = brick_grid;
        w[idx++] = float(chunk_size);
        w[idx++] = gravity.x;
        w[idx++] = gravity.y;
        w[idx++] = gravity.z;
        w[idx++] = 0.0f;
        Vector3 wb_x = world_basis.get_column(0);
        Vector3 wb_y = world_basis.get_column(1);
        Vector3 wb_z = world_basis.get_column(2);
        w[idx++] = wb_x.x;
        w[idx++] = wb_x.y;
        w[idx++] = wb_x.z;
        w[idx++] = 0.0f;
        w[idx++] = wb_y.x;
        w[idx++] = wb_y.y;
        w[idx++] = wb_y.z;
        w[idx++] = 0.0f;
        w[idx++] = wb_z.x;
        w[idx++] = wb_z.y;
        w[idx++] = wb_z.z;
        w[idx++] = 0.0f;

        PackedByteArray bytes = params.to_byte_array();
        _update_params(bytes);
        _debug_log_snapshot(pos, basis, world_extent);
        _dispatch_sim(grid_extent_i);
        _reset_metrics();
        _dispatch_occupancy();
        _dispatch_active_list();
        _dispatch_active_dispatch();
        _dispatch_light(grid_extent_i);
        _dispatch_compute();
        _readback_metrics();
        _debug_request_probe();
}

void VoxelRenderer::_update_params(const PackedByteArray &p_bytes) {
        if (_rd == nullptr || !_ubo_rid.is_valid()) {
                return;
        }
        _rd->buffer_update(_ubo_rid, 0, p_bytes.size(), p_bytes.ptr());
}

Vector3 VoxelRenderer::_normalized_gravity() const {
        if (gravity_dir.length() < 0.001f) {
                return Vector3(0.0f, -1.0f, 0.0f);
        }
        return gravity_dir.normalized();
}

void VoxelRenderer::_prime_active_list() {
        if (_active_list_ready) {
                return;
        }
        _dispatch_active_list();
        _dispatch_active_dispatch();
}

void VoxelRenderer::_rebuild_raymarch_uniform_sets() {
        if (_rd == nullptr || !_shader_rid.is_valid() || !_texture_rid.is_valid() || !_ubo_rid.is_valid()) {
                return;
        }
        RD::Uniform img_uniform;
        img_uniform.uniform_type = RD::UNIFORM_TYPE_IMAGE;
        img_uniform.binding = 0;
        img_uniform.append_id(_texture_rid);

        RD::Uniform ubo_uniform;
        ubo_uniform.uniform_type = RD::UNIFORM_TYPE_UNIFORM_BUFFER;
        ubo_uniform.binding = 1;
        ubo_uniform.append_id(_ubo_rid);

        RD::Uniform indirection_uniform;
        indirection_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        indirection_uniform.binding = 2;
        indirection_uniform.append_id(_indirection_rid);

        RD::Uniform atlas_uniform_a;
        atlas_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        atlas_uniform_a.binding = 3;
        atlas_uniform_a.append_id(_atlas_a_rid);

        RD::Uniform atlas_uniform_b;
        atlas_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        atlas_uniform_b.binding = 3;
        atlas_uniform_b.append_id(_atlas_b_rid);

        RD::Uniform occupancy_uniform;
        occupancy_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        occupancy_uniform.binding = 4;
        occupancy_uniform.append_id(_occupancy_rid);

        RD::Uniform metrics_uniform;
        metrics_uniform.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        metrics_uniform.binding = 5;
        metrics_uniform.append_id(_metrics_rid);

        RD::Uniform light_uniform_a;
        light_uniform_a.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        light_uniform_a.binding = 6;
        light_uniform_a.append_id(_light_a_rid);

        RD::Uniform light_uniform_b;
        light_uniform_b.uniform_type = RD::UNIFORM_TYPE_STORAGE_BUFFER;
        light_uniform_b.binding = 6;
        light_uniform_b.append_id(_light_b_rid);

        Vector<RD::Uniform> ray_uniforms_a_light_a;
        ray_uniforms_a_light_a.push_back(img_uniform);
        ray_uniforms_a_light_a.push_back(ubo_uniform);
        ray_uniforms_a_light_a.push_back(indirection_uniform);
        ray_uniforms_a_light_a.push_back(atlas_uniform_a);
        ray_uniforms_a_light_a.push_back(occupancy_uniform);
        ray_uniforms_a_light_a.push_back(metrics_uniform);
        ray_uniforms_a_light_a.push_back(light_uniform_a);
        _uniform_set_a_light_a_rid = _rd->uniform_set_create(ray_uniforms_a_light_a, _shader_rid, 0);

        Vector<RD::Uniform> ray_uniforms_a_light_b = ray_uniforms_a_light_a;
        ray_uniforms_a_light_b.write[6] = light_uniform_b;
        _uniform_set_a_light_b_rid = _rd->uniform_set_create(ray_uniforms_a_light_b, _shader_rid, 0);

        Vector<RD::Uniform> ray_uniforms_b_light_a = ray_uniforms_a_light_a;
        ray_uniforms_b_light_a.write[3] = atlas_uniform_b;
        ray_uniforms_b_light_a.write[6] = light_uniform_a;
        _uniform_set_b_light_a_rid = _rd->uniform_set_create(ray_uniforms_b_light_a, _shader_rid, 0);

        Vector<RD::Uniform> ray_uniforms_b_light_b = ray_uniforms_a_light_a;
        ray_uniforms_b_light_b.write[3] = atlas_uniform_b;
        ray_uniforms_b_light_b.write[6] = light_uniform_b;
        _uniform_set_b_light_b_rid = _rd->uniform_set_create(ray_uniforms_b_light_b, _shader_rid, 0);

        _raymarch_img_rid = _texture_rid;
        print_line(vformat("VoxelRenderer rebuild raymarch uniforms | img_rid=%d", _raymarch_img_rid.get_id()));
}

void VoxelRenderer::_dispatch_sim(int p_grid_extent) {
        (void)p_grid_extent;
        if (!sim_enabled) {
                return;
        }
        if (!_sim_pipeline_rid.is_valid()) {
                return;
        }
        _sim_frame += 1;
        int every = sim_every;
        if (every < 1) {
                every = 1;
        }
        if ((_sim_frame % every) != 0) {
                return;
        }
        bool use_a = _atlas_use_a;
        RID uniform_set = use_a ? _sim_uniform_set_ab : _sim_uniform_set_ba;
        if (!uniform_set.is_valid()) {
                return;
        }
        if (!_sim_dispatch_rid.is_valid()) {
                return;
        }
        if (!_active_list_ready) {
                return;
        }
        RID atlas_out = use_a ? _atlas_b_rid : _atlas_a_rid;
        if (sim_clear_output && _atlas_bytes > 0) {
                _rd->buffer_clear(atlas_out, 0, _atlas_bytes);
        }
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _sim_pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, uniform_set, 0);
        _rd->compute_list_dispatch_indirect(list, _sim_dispatch_rid, 0);
        _rd->compute_list_end();
        _atlas_use_a = !use_a;
        if (debug_logging) {
                print_line(vformat("VoxelRenderer sim dispatch | frame=%d use_a=%s dispatch_buffer=%d",
                        _sim_frame,
                        use_a,
                        _sim_dispatch_rid.get_id()));
        }
}

void VoxelRenderer::_reset_metrics() {
        if (!_metrics_rid.is_valid()) {
                return;
        }
        _rd->buffer_clear(_metrics_rid, 0, _metrics_bytes);
}

void VoxelRenderer::_dispatch_occupancy() {
        if (!_occupancy_pipeline_rid.is_valid()) {
                return;
        }
        RID uniform_set = _atlas_use_a ? _occupancy_uniform_set_a_rid : _occupancy_uniform_set_b_rid;
        if (!uniform_set.is_valid()) {
                return;
        }
        _rd->buffer_clear(_occupancy_rid, 0, _occupancy_bytes);
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _occupancy_pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, uniform_set, 0);
        int brick_count = chunk_grid * chunk_grid * chunk_grid;
        _rd->compute_list_dispatch(list, brick_count, 1, 1);
        _rd->compute_list_end();
        if (debug_logging) {
                print_line(vformat("VoxelRenderer occupancy dispatch | brick_count=%d use_a=%s",
                        brick_count,
                        _atlas_use_a));
        }
}

void VoxelRenderer::_dispatch_active_list() {
        if (!_active_list_pipeline_rid.is_valid()) {
                return;
        }
        if (!_active_list_uniform_set_rid.is_valid()) {
                return;
        }
        _active_list_ready = false;
        if (_active_count_bytes > 0) {
                _rd->buffer_clear(_active_count_rid, 0, _active_count_bytes);
        }
        int brick_count = chunk_grid * chunk_grid * chunk_grid;
        if (brick_count <= 0) {
                return;
        }
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _active_list_pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, _active_list_uniform_set_rid, 0);
        _rd->compute_list_dispatch(list, brick_count, 1, 1);
        _rd->compute_list_end();
        if (debug_logging) {
                print_line(vformat("VoxelRenderer active_list dispatch | brick_count=%d", brick_count));
        }
}

void VoxelRenderer::_dispatch_active_dispatch() {
        if (!_active_dispatch_pipeline_rid.is_valid()) {
                return;
        }
        if (!_active_dispatch_uniform_set_rid.is_valid()) {
                return;
        }
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _active_dispatch_pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, _active_dispatch_uniform_set_rid, 0);
        _rd->compute_list_dispatch(list, 1, 1, 1);
        _rd->compute_list_end();
        _active_list_ready = true;
        if (debug_logging) {
                print_line("VoxelRenderer active_dispatch dispatch | groups=1");
        }
}

void VoxelRenderer::_dispatch_light(int p_grid_extent) {
        if (!light_enabled) {
                return;
        }
        if (!_light_pipeline_rid.is_valid()) {
                return;
        }
        _light_frame += 1;
        int every = light_every;
        if (every < 1) {
                every = 1;
        }
        if ((_light_frame % every) != 0) {
                return;
        }
        RID uniform_set = _current_light_uniform_set();
        if (!uniform_set.is_valid()) {
                return;
        }
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _light_pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, uniform_set, 0);
        int groups = int(Math::ceil(float(p_grid_extent) / 4.0f));
        _rd->compute_list_dispatch(list, groups, groups, groups);
        _rd->compute_list_end();
        _light_use_a = !_light_use_a;
        if (debug_logging) {
                print_line(vformat("VoxelRenderer light dispatch | grid_extent=%d groups=%d use_a=%s",
                        p_grid_extent,
                        groups,
                        _light_use_a));
        }
}

RID VoxelRenderer::_current_raymarch_uniform_set() const {
        if (_atlas_use_a) {
                return _light_use_a ? _uniform_set_a_light_a_rid : _uniform_set_a_light_b_rid;
        }
        return _light_use_a ? _uniform_set_b_light_a_rid : _uniform_set_b_light_b_rid;
}

RID VoxelRenderer::_current_light_uniform_set() const {
        if (_atlas_use_a) {
                return _light_use_a ? _light_uniform_set_a_ab : _light_uniform_set_a_ba;
        }
        return _light_use_a ? _light_uniform_set_b_ab : _light_uniform_set_b_ba;
}

void VoxelRenderer::_readback_metrics() {
        _metrics_frame += 1;
        int every = metrics_every;
        if (every < 1) {
                every = 1;
        }
        if ((_metrics_frame % every) != 0) {
                return;
        }
        if (!_metrics_rid.is_valid()) {
                return;
        }
        RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &VoxelRenderer::_readback_metrics_on_render_thread));
}

void VoxelRenderer::_readback_metrics_on_render_thread() {
        if (_rd == nullptr || !_metrics_rid.is_valid()) {
                return;
        }
        PackedByteArray bytes = _rd->buffer_get_data(_metrics_rid);
        if (bytes.size() < 16) {
                return;
        }
        int32_t vals[4] = {};
        memcpy(vals, bytes.ptr(), sizeof(vals));
        int ray_count = vals[0];
        int hit_count = vals[1];
        int step_count = vals[2];
        int occupied_bricks = vals[3];
        int active_bricks = -1;
        if (_active_count_rid.is_valid()) {
                PackedByteArray active_bytes = _rd->buffer_get_data(_active_count_rid, 0, 4);
                if (active_bytes.size() >= 4) {
                        int32_t active_val = 0;
                        memcpy(&active_val, active_bytes.ptr(), sizeof(active_val));
                        active_bricks = active_val;
                }
        }
        float avg_steps = 0.0f;
        if (ray_count > 0) {
                avg_steps = float(step_count) / float(ray_count);
        }
        bool main_thread = Thread::is_main_thread();
        int total_bricks = chunk_grid * chunk_grid * chunk_grid;
        int groups_per_brick = int(Math::ceil(float(chunk_size) / 4.0f));
        int indirect_groups = -1;
        int full_groups = int(Math::ceil(float(chunk_grid * chunk_size) / 4.0f));
        if (active_bricks >= 0) {
                indirect_groups = active_bricks * groups_per_brick * groups_per_brick * groups_per_brick;
        }
        int full_group_count = full_groups * full_groups * full_groups;
        print_line(vformat("GPU metrics | rays=%d hits=%d avg_steps=%.2f occupied_bricks=%d active_bricks=%d total_bricks=%d indirect_groups=%d full_groups=%d main_thread=%s",
                ray_count,
                hit_count,
                avg_steps,
                occupied_bricks,
                active_bricks,
                total_bricks,
                indirect_groups,
                full_group_count,
                main_thread));

}

void VoxelRenderer::_dispatch_compute() {
        if (!_render_ready || !_pipeline_rid.is_valid()) {
                return;
        }
        RID uniform_set = _current_raymarch_uniform_set();
        if (!uniform_set.is_valid()) {
                return;
        }
        RenderingDevice::ComputeListID list = _rd->compute_list_begin();
        _rd->compute_list_bind_compute_pipeline(list, _pipeline_rid);
        _rd->compute_list_bind_uniform_set(list, uniform_set, 0);
        int groups_x = int(Math::ceil(float(width) / 8.0f));
        int groups_y = int(Math::ceil(float(height) / 8.0f));
        _rd->compute_list_dispatch(list, groups_x, groups_y, 1);
        _rd->compute_list_end();
        if (debug_logging) {
                print_line(vformat("VoxelRenderer raymarch dispatch | groups=(%d,%d,1) atlas_use_a=%s light_use_a=%s img_rid=%d",
                        groups_x, groups_y, _atlas_use_a, _light_use_a, _raymarch_img_rid.get_id()));
        }

        // GPU-only MPM metrics dispatch.
}

void VoxelRenderer::_upload_brickmap_data() {
        int brick_grid = chunk_grid;
        int brick_count = brick_grid * brick_grid * brick_grid;
        PackedInt32Array indirection;
        PackedInt32Array occupancy;
        indirection.resize(brick_count);
        occupancy.resize(brick_count);
        indirection.fill(0);
        occupancy.fill(0);

        PackedInt32Array atlas;
        atlas.resize(brick_count * chunk_size * chunk_size * chunk_size);
        atlas.fill(0);

        int grid_extent = brick_grid * chunk_size;
        Vector3 center((grid_extent - 1) * 0.5f, (grid_extent - 1) * 0.5f, (grid_extent - 1) * 0.5f);
        float fill_radius = float(grid_extent) * fill_radius_ratio;
        float fill_radius_sq = fill_radius * fill_radius;
        Array entries = _load_voxel_entries(grid_extent);
        if (entries.size() > 0) {
                for (int i = 0; i < entries.size(); i++) {
                        Dictionary entry = entries[i];
                        Vector3 pos = entry.get("pos", Vector3());
                        int mat_id = int(entry.get("material", 1));
                        if (mat_id <= 0) {
                                continue;
                        }
                        int gx = int(pos.x);
                        int gy = int(pos.y);
                        int gz = int(pos.z);
                        if (gx < 0 || gy < 0 || gz < 0 || gx >= grid_extent || gy >= grid_extent || gz >= grid_extent) {
                                continue;
                        }
                        if (!_bcc_parity(Vector3i(gx, gy, gz))) {
                                continue;
                        }
                        int bx = gx / chunk_size;
                        int by = gy / chunk_size;
                        int bz = gz / chunk_size;
                        int lx = gx - bx * chunk_size;
                        int ly = gy - by * chunk_size;
                        int lz = gz - bz * chunk_size;
                        int brick_index = bx + by * brick_grid + bz * brick_grid * brick_grid;
                        int base_offset = brick_index * chunk_size * chunk_size * chunk_size;
                        int local_index = base_offset + lx + ly * chunk_size + lz * chunk_size * chunk_size;
                        atlas.write[local_index] = mat_id;
                        occupancy.write[brick_index] = 1;
                        indirection.write[brick_index] = brick_index + 1;
                }
        } else {
                for (int bz = 0; bz < brick_grid; bz++) {
                        for (int by = 0; by < brick_grid; by++) {
                                for (int bx = 0; bx < brick_grid; bx++) {
                                        int brick_index = bx + by * brick_grid + bz * brick_grid * brick_grid;
                                        int base_offset = brick_index * chunk_size * chunk_size * chunk_size;
                                        bool any = false;
                                        for (int lz = 0; lz < chunk_size; lz++) {
                                                int gz = bz * chunk_size + lz;
                                                for (int ly = 0; ly < chunk_size; ly++) {
                                                        int gy = by * chunk_size + ly;
                                                        for (int lx = 0; lx < chunk_size; lx++) {
                                                                int gx = bx * chunk_size + lx;
                                                                if (!_bcc_parity(Vector3i(gx, gy, gz))) {
                                                                        continue;
                                                                }
                                                                Vector3 delta = Vector3(float(gx), float(gy), float(gz)) - center;
                                                                if (delta.length_squared() > fill_radius_sq) {
                                                                        continue;
                                                                }
                                                                if (fill_mode == 1) {
                                                                        int64_t h = (int64_t(gx) * 73856093) ^ (int64_t(gy) * 19349663) ^ (int64_t(gz) * 83492791);
                                                                        float n = float(h & 1023) / 1023.0f;
                                                                        if (n < noise_threshold) {
                                                                                continue;
                                                                        }
                                                                }
                                                                int local_index = base_offset + lx + ly * chunk_size + lz * chunk_size * chunk_size;
                                                                atlas.write[local_index] = 1;
                                                                any = true;
                                                        }
                                                }
                                        }
                                        if (any) {
                                                occupancy.write[brick_index] = 1;
                                                indirection.write[brick_index] = brick_index + 1;
                                        } else {
                                                indirection.write[brick_index] = 0;
                                        }
                                }
                        }
                }
        }

        PackedByteArray ind_bytes = indirection.to_byte_array();
        _rd->buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes.ptr());
        _indirection_cpu = indirection;
        PackedByteArray atlas_bytes = atlas.to_byte_array();
        if (_atlas_a_rid.is_valid()) {
                _rd->buffer_update(_atlas_a_rid, 0, atlas_bytes.size(), atlas_bytes.ptr());
        }
        if (_atlas_b_rid.is_valid()) {
                _rd->buffer_update(_atlas_b_rid, 0, atlas_bytes.size(), atlas_bytes.ptr());
        }
        _atlas_use_a = true;
        PackedByteArray occ_bytes = occupancy.to_byte_array();
        _rd->buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes.ptr());
}

void VoxelRenderer::set_voxel_entries(const Array &p_entries, bool p_allocate_all_bricks) {
        if (_rd == nullptr) {
                return;
        }
        _active_list_ready = false;
        int brick_grid = chunk_grid;
        int brick_count = brick_grid * brick_grid * brick_grid;
        PackedInt32Array indirection;
        PackedInt32Array occupancy;
        indirection.resize(brick_count);
        occupancy.resize(brick_count);
        for (int i = 0; i < brick_count; i++) {
                indirection.write[i] = p_allocate_all_bricks ? (i + 1) : 0;
                occupancy.write[i] = 0;
        }

        PackedInt32Array atlas;
        atlas.resize(brick_count * chunk_size * chunk_size * chunk_size);
        atlas.fill(0);

        int grid_extent = brick_grid * chunk_size;
        for (int i = 0; i < p_entries.size(); i++) {
                Dictionary entry = p_entries[i];
                Vector3 pos = entry.get("pos", Vector3());
                int mat_id = int(entry.get("material", 1));
                if (mat_id <= 0) {
                        continue;
                }
                int gx = int(pos.x);
                int gy = int(pos.y);
                int gz = int(pos.z);
                if (gx < 0 || gy < 0 || gz < 0 || gx >= grid_extent || gy >= grid_extent || gz >= grid_extent) {
                        continue;
                }
                if (!_bcc_parity(Vector3i(gx, gy, gz))) {
                        continue;
                }
                int bx = gx / chunk_size;
                int by = gy / chunk_size;
                int bz = gz / chunk_size;
                int lx = gx - bx * chunk_size;
                int ly = gy - by * chunk_size;
                int lz = gz - bz * chunk_size;
                int brick_index = bx + by * brick_grid + bz * brick_grid * brick_grid;
                int base_offset = brick_index * chunk_size * chunk_size * chunk_size;
                int local_index = base_offset + lx + ly * chunk_size + lz * chunk_size * chunk_size;
                atlas.write[local_index] = mat_id;
                occupancy.write[brick_index] = 1;
                if (!p_allocate_all_bricks) {
                        indirection.write[brick_index] = brick_index + 1;
                }
        }

        PackedByteArray ind_bytes = indirection.to_byte_array();
        _rd->buffer_update(_indirection_rid, 0, ind_bytes.size(), ind_bytes.ptr());
        _indirection_cpu = indirection;
        PackedByteArray atlas_bytes = atlas.to_byte_array();
        if (_atlas_a_rid.is_valid()) {
                _rd->buffer_update(_atlas_a_rid, 0, atlas_bytes.size(), atlas_bytes.ptr());
        }
        if (_atlas_b_rid.is_valid()) {
                _rd->buffer_update(_atlas_b_rid, 0, atlas_bytes.size(), atlas_bytes.ptr());
        }
        _atlas_use_a = true;
        PackedByteArray occ_bytes = occupancy.to_byte_array();
        _rd->buffer_update(_occupancy_rid, 0, occ_bytes.size(), occ_bytes.ptr());
        if (_light_a_rid.is_valid()) {
                _rd->buffer_clear(_light_a_rid, 0, _atlas_bytes);
        }
        if (_light_b_rid.is_valid()) {
                _rd->buffer_clear(_light_b_rid, 0, _atlas_bytes);
        }
}

Array VoxelRenderer::_load_voxel_entries(int p_grid_extent) const {
        (void)p_grid_extent;
        Array entries;
        if (voxel_data_path.is_empty()) {
                return entries;
        }
        if (!FileAccess::exists(voxel_data_path)) {
                return entries;
        }
        Error err = OK;
        String text = FileAccess::get_file_as_string(voxel_data_path, &err);
        if (err != OK || text.is_empty()) {
                return entries;
        }
        Variant json_data = JSON::parse_string(text);
        if (json_data.get_type() != Variant::DICTIONARY) {
                return entries;
        }
        Dictionary dict = json_data;
        Variant voxels_var = dict.get("voxels", Array());
        if (voxels_var.get_type() != Variant::ARRAY) {
                return entries;
        }
        Array voxels = voxels_var;
        for (int i = 0; i < voxels.size(); i++) {
                Array arr = voxels[i];
                if (arr.size() < 3) {
                        continue;
                }
                int mat_id = 1;
                if (arr.size() >= 4) {
                        mat_id = int(arr[3]);
                }
                Dictionary entry;
                entry["pos"] = Vector3(float(arr[0]), float(arr[1]), float(arr[2]));
                entry["material"] = mat_id;
                entries.push_back(entry);
        }
        return entries;
}

void VoxelRenderer::_debug_log_snapshot(const Vector3 &p_pos, const Basis &p_basis, float p_world_extent) {
        if (!debug_logging) {
                return;
        }
        int every = debug_log_every;
        if (every < 1) {
                every = 1;
        }
        if ((_debug_frame % every) != 0) {
                return;
        }
        Vector3 grid_min(-0.5f * p_world_extent, -0.5f * p_world_extent, -0.5f * p_world_extent);
        Vector3 grid_max = grid_min + Vector3(1.0f, 1.0f, 1.0f) * p_world_extent;
        bool cam_inside = (
                p_pos.x >= grid_min.x && p_pos.x <= grid_max.x &&
                p_pos.y >= grid_min.y && p_pos.y <= grid_max.y &&
                p_pos.z >= grid_min.z && p_pos.z <= grid_max.z);
        Vector3 forward = -p_basis.get_column(2);
        bool main_thread = Thread::is_main_thread();
        bool pipeline_ok = _pipeline_rid.is_valid();
        print_line(vformat("VoxelRenderer debug | frame=%d main_thread=%s cam_pos=%s cam_fwd=%s cam_inside=%s render_ready=%s pipeline=%s probe=%s",
                _debug_frame,
                main_thread,
                p_pos,
                forward,
                cam_inside,
                _render_ready,
                pipeline_ok,
                debug_probe_enabled));
        if (debug_render_thread_ping) {
                RenderingServer::get_singleton()->call_on_render_thread(
                        callable_mp(this, &VoxelRenderer::_debug_render_thread_ping).bind(_debug_frame));
        }
}

void VoxelRenderer::_debug_render_thread_ping(int p_frame_id) {
        bool main_thread = Thread::is_main_thread();
        bool rd_valid = _rd != nullptr;
        print_line(vformat("VoxelRenderer render thread | frame=%d main_thread=%s rd_valid=%s",
                p_frame_id,
                main_thread,
                rd_valid));
}

bool VoxelRenderer::_bcc_parity(const Vector3i &p_cell) const {
        return ((p_cell.x & 1) == (p_cell.y & 1)) && ((p_cell.y & 1) == (p_cell.z & 1));
}

RID VoxelRenderer::_current_atlas_rid() const {
        return _atlas_use_a ? _atlas_a_rid : _atlas_b_rid;
}

void VoxelRenderer::set_debug_probe_cell_xyz(int p_x, int p_y, int p_z) {
        debug_probe_cell = Vector3i(p_x, p_y, p_z);
}

void VoxelRenderer::_debug_request_probe() {
        if (!debug_probe_enabled) {
                return;
        }
        int every = debug_probe_every;
        if (every < 1) {
                every = 1;
        }
        _debug_probe_frame += 1;
        if ((_debug_probe_frame % every) != 0) {
                return;
        }
        if (_indirection_cpu.is_empty()) {
                print_line(vformat("VoxelRenderer probe | frame=%d indirection_cpu=empty", _debug_frame));
                return;
        }
        int grid_extent = chunk_grid * chunk_size;
        Vector3i cell = debug_probe_cell;
        bool parity = _bcc_parity(cell);
        bool in_bounds = (
                cell.x >= 0 && cell.y >= 0 && cell.z >= 0 &&
                cell.x < grid_extent && cell.y < grid_extent && cell.z < grid_extent);
        if (!in_bounds) {
                print_line(vformat("VoxelRenderer probe | frame=%d cell=%s out_of_bounds grid_extent=%d parity=%s",
                        _debug_frame,
                        cell,
                        grid_extent,
                        parity));
                return;
        }
        int brick_size = chunk_size;
        int bx = int(cell.x / brick_size);
        int by = int(cell.y / brick_size);
        int bz = int(cell.z / brick_size);
        if (bx < 0 || by < 0 || bz < 0 || bx >= chunk_grid || by >= chunk_grid || bz >= chunk_grid) {
                print_line(vformat("VoxelRenderer probe | frame=%d cell=%s brick_out_of_bounds brick=%s",
                        _debug_frame,
                        cell,
                        Vector3i(bx, by, bz)));
                return;
        }
        int brick_index = bx + by * chunk_grid + bz * chunk_grid * chunk_grid;
        if (brick_index < 0 || brick_index >= _indirection_cpu.size()) {
                print_line(vformat("VoxelRenderer probe | frame=%d cell=%s brick_index_out_of_range=%d",
                        _debug_frame,
                        cell,
                        brick_index));
                return;
        }
        int ind = _indirection_cpu[brick_index];
        if (ind <= 0) {
                print_line(vformat("VoxelRenderer probe | frame=%d cell=%s parity=%s ind=%d brick_index=%d",
                        _debug_frame,
                        cell,
                        parity,
                        ind,
                        brick_index));
                return;
        }
        int lx = cell.x - bx * brick_size;
        int ly = cell.y - by * brick_size;
        int lz = cell.z - bz * brick_size;
        int local_index = lx + ly * brick_size + lz * brick_size * brick_size;
        int bricks_total = chunk_grid * chunk_grid * chunk_grid;
        int atlas_size = bricks_total * brick_size * brick_size * brick_size;
        int atlas_index = (ind - 1) * brick_size * brick_size * brick_size + local_index;
        if (atlas_index < 0 || atlas_index >= atlas_size) {
                print_line(vformat("VoxelRenderer probe | frame=%d cell=%s atlas_index_out_of_range=%d size=%d",
                        _debug_frame,
                        cell,
                        atlas_index,
                        atlas_size));
                return;
        }
        int atlas_offset = atlas_index * 4;
        int occ_offset = brick_index * 4;
        RID atlas_rid = _current_atlas_rid();
        RenderingServer::get_singleton()->call_on_render_thread(
                callable_mp(this, &VoxelRenderer::_debug_probe_readback_on_render_thread).bind(
                        _debug_frame,
                        cell,
                        parity,
                        ind,
                        atlas_index,
                        atlas_offset,
                        occ_offset,
                        atlas_rid));
}

void VoxelRenderer::_debug_probe_readback_on_render_thread(int p_frame_id, const Vector3i &p_cell, bool p_parity, int p_ind, int p_atlas_index, int p_atlas_offset, int p_occ_offset, RID p_atlas_rid) {
        if (_rd == nullptr) {
                return;
        }
        if (!p_atlas_rid.is_valid()) {
                return;
        }
        PackedByteArray atlas_bytes = _rd->buffer_get_data(p_atlas_rid, p_atlas_offset, 4);
        PackedByteArray occ_bytes;
        if (_occupancy_rid.is_valid()) {
                occ_bytes = _rd->buffer_get_data(_occupancy_rid, p_occ_offset, 4);
        }
        if (atlas_bytes.size() < 4) {
                return;
        }
        int atlas_val = 0;
        memcpy(&atlas_val, atlas_bytes.ptr(), sizeof(atlas_val));
        int occ_val = 0;
        if (occ_bytes.size() >= 4) {
                memcpy(&occ_val, occ_bytes.ptr(), sizeof(occ_val));
        }
        bool main_thread = Thread::is_main_thread();
        print_line(vformat("VoxelRenderer probe | frame=%d cell=%s parity=%s ind=%d atlas_index=%d atlas_val=%d occ_val=%d main_thread=%s",
                p_frame_id,
                p_cell,
                p_parity,
                p_ind,
                p_atlas_index,
                atlas_val,
                occ_val,
                main_thread));
}

void VoxelRenderer::set_quad_path(const NodePath &p_path) {
        quad_path = p_path;
}

NodePath VoxelRenderer::get_quad_path() const {
        return quad_path;
}

void VoxelRenderer::set_camera_path(const NodePath &p_path) {
        camera_path = p_path;
}

NodePath VoxelRenderer::get_camera_path() const {
        return camera_path;
}

void VoxelRenderer::set_width(int p_width) {
        width = p_width;
}

int VoxelRenderer::get_width() const {
        return width;
}

void VoxelRenderer::set_height(int p_height) {
        height = p_height;
}

int VoxelRenderer::get_height() const {
        return height;
}

void VoxelRenderer::set_chunk_size(int p_chunk_size) {
        chunk_size = p_chunk_size;
}

int VoxelRenderer::get_chunk_size() const {
        return chunk_size;
}

void VoxelRenderer::set_chunk_grid(int p_chunk_grid) {
        chunk_grid = p_chunk_grid;
}

int VoxelRenderer::get_chunk_grid() const {
        return chunk_grid;
}

void VoxelRenderer::set_lattice_spacing(float p_spacing) {
        lattice_spacing = p_spacing;
}

float VoxelRenderer::get_lattice_spacing() const {
        return lattice_spacing;
}

void VoxelRenderer::set_max_distance(float p_distance) {
        max_distance = p_distance;
}

float VoxelRenderer::get_max_distance() const {
        return max_distance;
}

void VoxelRenderer::set_auto_max_distance(bool p_enabled) {
        auto_max_distance = p_enabled;
}

bool VoxelRenderer::is_auto_max_distance() const {
        return auto_max_distance;
}

void VoxelRenderer::set_fill_radius_ratio(float p_ratio) {
        fill_radius_ratio = p_ratio;
}

float VoxelRenderer::get_fill_radius_ratio() const {
        return fill_radius_ratio;
}

void VoxelRenderer::set_fill_mode(int p_mode) {
        fill_mode = p_mode;
}

int VoxelRenderer::get_fill_mode() const {
        return fill_mode;
}

void VoxelRenderer::set_noise_threshold(float p_threshold) {
        noise_threshold = p_threshold;
}

float VoxelRenderer::get_noise_threshold() const {
        return noise_threshold;
}

void VoxelRenderer::set_voxel_data_path(const String &p_path) {
        voxel_data_path = p_path;
}

String VoxelRenderer::get_voxel_data_path() const {
        return voxel_data_path;
}

void VoxelRenderer::set_gravity_dir(const Vector3 &p_gravity) {
        gravity_dir = p_gravity;
}

Vector3 VoxelRenderer::get_gravity_dir() const {
        return gravity_dir;
}

void VoxelRenderer::set_world_rotation(const Vector3 &p_rotation) {
        world_rotation = p_rotation;
}

Vector3 VoxelRenderer::get_world_rotation() const {
        return world_rotation;
}

void VoxelRenderer::set_light_enabled(bool p_enabled) {
        light_enabled = p_enabled;
}

bool VoxelRenderer::is_light_enabled() const {
        return light_enabled;
}

void VoxelRenderer::set_light_every(int p_every) {
        light_every = p_every;
}

int VoxelRenderer::get_light_every() const {
        return light_every;
}

void VoxelRenderer::set_metrics_every(int p_every) {
        metrics_every = p_every;
}

int VoxelRenderer::get_metrics_every() const {
        return metrics_every;
}

void VoxelRenderer::set_debug_logging(bool p_enabled) {
        debug_logging = p_enabled;
}

bool VoxelRenderer::is_debug_logging() const {
        return debug_logging;
}

void VoxelRenderer::set_debug_log_every(int p_every) {
        debug_log_every = p_every;
}

int VoxelRenderer::get_debug_log_every() const {
        return debug_log_every;
}

void VoxelRenderer::set_debug_render_thread_ping(bool p_enabled) {
        debug_render_thread_ping = p_enabled;
}

bool VoxelRenderer::is_debug_render_thread_ping() const {
        return debug_render_thread_ping;
}

void VoxelRenderer::set_debug_probe_enabled(bool p_enabled) {
        debug_probe_enabled = p_enabled;
}

bool VoxelRenderer::is_debug_probe_enabled() const {
        return debug_probe_enabled;
}

void VoxelRenderer::set_debug_probe_cell(const Vector3i &p_cell) {
        debug_probe_cell = p_cell;
}

Vector3i VoxelRenderer::get_debug_probe_cell() const {
        return debug_probe_cell;
}

void VoxelRenderer::set_debug_probe_every(int p_every) {
        debug_probe_every = p_every;
}

int VoxelRenderer::get_debug_probe_every() const {
        return debug_probe_every;
}

void VoxelRenderer::set_sim_enabled(bool p_enabled) {
        sim_enabled = p_enabled;
}

bool VoxelRenderer::is_sim_enabled() const {
        return sim_enabled;
}

void VoxelRenderer::set_sim_every(int p_every) {
        sim_every = p_every;
}

int VoxelRenderer::get_sim_every() const {
        return sim_every;
}

void VoxelRenderer::set_sim_clear_output(bool p_clear) {
        sim_clear_output = p_clear;
}

bool VoxelRenderer::is_sim_clear_output() const {
        return sim_clear_output;
}

Dictionary VoxelRenderer::get_render_debug_state() const {
        Dictionary state;
        state["debug_frame"] = _debug_frame;
        state["metrics_frame"] = _metrics_frame;
        state["light_frame"] = _light_frame;
        state["render_ready"] = _render_ready;
        state["pipeline_valid"] = _pipeline_rid.is_valid();
        state["shader_valid"] = _shader_rid.is_valid();
        state["texture_valid"] = _texture_rid.is_valid();
        state["texture_rid_id"] = _texture_rid.get_id();
        state["ubo_valid"] = _ubo_rid.is_valid();
        state["display_texture_valid"] = _display_texture.is_valid();
        state["display_material_valid"] = _display_material.is_valid();
        state["atlas_bytes"] = _atlas_bytes;
        state["occupancy_bytes"] = _occupancy_bytes;
        state["active_list_ready"] = _active_list_ready;
        state["chunk_size"] = chunk_size;
        state["chunk_grid"] = chunk_grid;
        state["active_list_uniform_set_valid"] = _active_list_uniform_set_rid.is_valid();
        state["active_dispatch_uniform_set_valid"] = _active_dispatch_uniform_set_rid.is_valid();
        state["sim_uniform_set_ab_valid"] = _sim_uniform_set_ab.is_valid();
        state["sim_uniform_set_ba_valid"] = _sim_uniform_set_ba.is_valid();
        state["occupancy_uniform_set_a_valid"] = _occupancy_uniform_set_a_rid.is_valid();
        state["occupancy_uniform_set_b_valid"] = _occupancy_uniform_set_b_rid.is_valid();
        state["camera_valid"] = _camera != nullptr;
        state["process_enabled"] = is_processing();

    bool display_tex_rd_valid = false;
    bool display_tex_rid_valid = false;
    bool display_tex_rs_rd_valid = false;
    bool display_tex_rs_rd_matches = false;
    if (_display_texture.is_valid()) {
        Ref<Texture2DRD> tex = _display_texture;
        if (tex.is_valid()) {
            display_tex_rd_valid = tex->get_texture_rd_rid().is_valid();
            display_tex_rid_valid = tex->get_rid().is_valid();
            RID rs_rd = RenderingServer::get_singleton()->texture_get_rd_texture(tex->get_rid());
            display_tex_rs_rd_valid = rs_rd.is_valid();
            display_tex_rs_rd_matches = rs_rd == _texture_rid;
            state["display_tex_rd_id"] = tex->get_texture_rd_rid().get_id();
            state["display_tex_rid_id"] = tex->get_rid().get_id();
            state["display_tex_rs_rd_id"] = rs_rd.get_id();
        }
    }
    state["display_tex_rd_valid"] = display_tex_rd_valid;
    state["display_tex_rid_valid"] = display_tex_rid_valid;
    state["display_tex_rs_rd_valid"] = display_tex_rs_rd_valid;
    state["display_tex_rs_rd_matches"] = display_tex_rs_rd_matches;

        bool compute_tex_set = false;
        bool compute_tex_is_texture = false;
        bool compute_tex_rid_valid = false;
        bool compute_tex_rd_valid = false;
        if (_display_material.is_valid()) {
                Variant compute_tex = _display_material->get_shader_parameter("compute_tex");
                compute_tex_set = compute_tex.get_type() != Variant::NIL;
                if (compute_tex.get_type() == Variant::OBJECT) {
                        Object *obj = compute_tex;
                        if (obj) {
                                Texture2D *tex = Object::cast_to<Texture2D>(obj);
                                if (tex) {
                                        compute_tex_is_texture = true;
                                        compute_tex_rid_valid = tex->get_rid().is_valid();
                                }
                                Texture2DRD *tex_rd = Object::cast_to<Texture2DRD>(obj);
                                if (tex_rd) {
                                        compute_tex_rd_valid = tex_rd->get_texture_rd_rid().is_valid();
                                }
                        }
                }
        }
        state["compute_tex_set"] = compute_tex_set;
        state["compute_tex_is_texture"] = compute_tex_is_texture;
        state["compute_tex_rid_valid"] = compute_tex_rid_valid;
        state["compute_tex_rd_valid"] = compute_tex_rd_valid;
        state["uniform_set_valid"] = _uniform_set_a_light_a_rid.is_valid();
        return state;
}

void VoxelRenderer::debug_rebind_display_texture() {
        if (_display_material.is_valid()) {
                _display_material->set_shader_parameter("compute_tex", _display_texture);
        }
}

void VoxelRenderer::debug_dump_buffers() {
        if (_rd == nullptr) {
                return;
        }
        RenderingServer::get_singleton()->call_on_render_thread(callable_mp(this, &VoxelRenderer::_debug_dump_buffers_on_render_thread));
}

void VoxelRenderer::_debug_dump_buffers_on_render_thread() {
        if (_rd == nullptr) {
                return;
        }
        print_line(vformat("VoxelRenderer dump | texture_rid=%d atlas_use_a=%s light_use_a=%s",
                _texture_rid.get_id(), _atlas_use_a, _light_use_a));
        if (_occupancy_rid.is_valid()) {
                PackedByteArray occ_bytes = _rd->buffer_get_data(_occupancy_rid, 0, MIN(_occupancy_bytes, 256));
                int occ_nonzero = 0;
                for (int i = 0; i < occ_bytes.size(); i += 4) {
                        int32_t v = 0;
                        memcpy(&v, occ_bytes.ptr() + i, sizeof(v));
                        if (v != 0) {
                                occ_nonzero++;
                        }
                }
                print_line(vformat("  occupancy bytes=%d first_chunk_nonzero=%d", occ_bytes.size(), occ_nonzero));
        }
        if (_atlas_a_rid.is_valid()) {
                PackedByteArray atlas_bytes = _rd->buffer_get_data(_atlas_a_rid, 0, MIN(_atlas_bytes, 256));
                int nonzero = 0;
                int first_val = 0;
                if (atlas_bytes.size() >= 4) {
                        memcpy(&first_val, atlas_bytes.ptr(), sizeof(first_val));
                }
                for (int i = 0; i < atlas_bytes.size(); i += 4) {
                        int32_t v = 0;
                        memcpy(&v, atlas_bytes.ptr() + i, sizeof(v));
                        if (v != 0) {
                                nonzero++;
                        }
                }
                print_line(vformat("  atlas_a bytes=%d first_val=%d nonzero_first_chunk=%d", atlas_bytes.size(), first_val, nonzero));
        }
}

void VoxelRenderer::debug_log_state() const {
        print_line(vformat("VoxelRenderer state | render_ready=%s pipeline=%s shader=%s texture=%s img_rid=%d display_rd=%s",
                _render_ready,
                _pipeline_rid.is_valid(),
                _shader_rid.is_valid(),
                _texture_rid.is_valid(),
                _texture_rid.get_id(),
                _display_texture.is_valid() ? _display_texture->get_texture_rd_rid().is_valid() : false));
}

String VoxelRenderer::debug_peek_buffers() const {
        if (_rd == nullptr) {
                return "rd=null";
        }
        String res;
        if (_occupancy_rid.is_valid()) {
                PackedByteArray occ_bytes = _rd->buffer_get_data(_occupancy_rid, 0, MIN(_occupancy_bytes, 256));
                int occ_nonzero = 0;
                for (int i = 0; i < occ_bytes.size(); i += 4) {
                        int32_t v = 0;
                        memcpy(&v, occ_bytes.ptr() + i, sizeof(v));
                        if (v != 0) {
                                occ_nonzero++;
                        }
                }
                res += vformat("occ bytes=%d nonzero=%d\n", occ_bytes.size(), occ_nonzero);
        }
        if (_atlas_a_rid.is_valid()) {
                PackedByteArray atlas_bytes = _rd->buffer_get_data(_atlas_a_rid, 0, MIN(_atlas_bytes, 256));
                int nonzero = 0;
                int first_val = 0;
                if (atlas_bytes.size() >= 4) {
                        memcpy(&first_val, atlas_bytes.ptr(), sizeof(first_val));
                }
                for (int i = 0; i < atlas_bytes.size(); i += 4) {
                        int32_t v = 0;
                        memcpy(&v, atlas_bytes.ptr() + i, sizeof(v));
                        if (v != 0) {
                                nonzero++;
                        }
                }
                res += vformat("atlas bytes=%d first=%d nonzero=%d\n", atlas_bytes.size(), first_val, nonzero);
        }
        return res;
}

Dictionary VoxelRenderer::debug_peek_metrics() const {
        Dictionary out;
        if (_rd == nullptr || !_metrics_rid.is_valid()) {
                return out;
        }
        PackedByteArray bytes = _rd->buffer_get_data(_metrics_rid, 0, MIN(_metrics_bytes, 16));
        if (bytes.size() >= 16) {
                int32_t vals[4] = {};
                memcpy(vals, bytes.ptr(), sizeof(vals));
                out["rays"] = vals[0];
                out["hits"] = vals[1];
                out["steps"] = vals[2];
                out["occupied_bricks"] = vals[3];
        }
        if (_active_count_rid.is_valid()) {
                PackedByteArray active_bytes = _rd->buffer_get_data(_active_count_rid, 0, 4);
                if (active_bytes.size() >= 4) {
                        int32_t active_val = 0;
                        memcpy(&active_val, active_bytes.ptr(), sizeof(active_val));
                        out["active_bricks"] = active_val;
                }
        }
        return out;
}

void VoxelRenderer::_bind_methods() {
        ClassDB::bind_method(D_METHOD("set_quad_path", "path"), &VoxelRenderer::set_quad_path);
        ClassDB::bind_method(D_METHOD("get_quad_path"), &VoxelRenderer::get_quad_path);
        ClassDB::bind_method(D_METHOD("set_camera_path", "path"), &VoxelRenderer::set_camera_path);
        ClassDB::bind_method(D_METHOD("get_camera_path"), &VoxelRenderer::get_camera_path);
        ClassDB::bind_method(D_METHOD("set_width", "width"), &VoxelRenderer::set_width);
        ClassDB::bind_method(D_METHOD("get_width"), &VoxelRenderer::get_width);
        ClassDB::bind_method(D_METHOD("set_height", "height"), &VoxelRenderer::set_height);
        ClassDB::bind_method(D_METHOD("get_height"), &VoxelRenderer::get_height);
        ClassDB::bind_method(D_METHOD("set_chunk_size", "chunk_size"), &VoxelRenderer::set_chunk_size);
        ClassDB::bind_method(D_METHOD("get_chunk_size"), &VoxelRenderer::get_chunk_size);
        ClassDB::bind_method(D_METHOD("set_chunk_grid", "chunk_grid"), &VoxelRenderer::set_chunk_grid);
        ClassDB::bind_method(D_METHOD("get_chunk_grid"), &VoxelRenderer::get_chunk_grid);
        ClassDB::bind_method(D_METHOD("set_lattice_spacing", "lattice_spacing"), &VoxelRenderer::set_lattice_spacing);
        ClassDB::bind_method(D_METHOD("get_lattice_spacing"), &VoxelRenderer::get_lattice_spacing);
        ClassDB::bind_method(D_METHOD("set_max_distance", "max_distance"), &VoxelRenderer::set_max_distance);
        ClassDB::bind_method(D_METHOD("get_max_distance"), &VoxelRenderer::get_max_distance);
        ClassDB::bind_method(D_METHOD("set_auto_max_distance", "enabled"), &VoxelRenderer::set_auto_max_distance);
        ClassDB::bind_method(D_METHOD("is_auto_max_distance"), &VoxelRenderer::is_auto_max_distance);
        ClassDB::bind_method(D_METHOD("set_fill_radius_ratio", "ratio"), &VoxelRenderer::set_fill_radius_ratio);
        ClassDB::bind_method(D_METHOD("get_fill_radius_ratio"), &VoxelRenderer::get_fill_radius_ratio);
        ClassDB::bind_method(D_METHOD("set_fill_mode", "mode"), &VoxelRenderer::set_fill_mode);
        ClassDB::bind_method(D_METHOD("get_fill_mode"), &VoxelRenderer::get_fill_mode);
        ClassDB::bind_method(D_METHOD("set_noise_threshold", "threshold"), &VoxelRenderer::set_noise_threshold);
        ClassDB::bind_method(D_METHOD("get_noise_threshold"), &VoxelRenderer::get_noise_threshold);
        ClassDB::bind_method(D_METHOD("set_voxel_data_path", "path"), &VoxelRenderer::set_voxel_data_path);
        ClassDB::bind_method(D_METHOD("get_voxel_data_path"), &VoxelRenderer::get_voxel_data_path);
        ClassDB::bind_method(D_METHOD("set_gravity_dir", "gravity"), &VoxelRenderer::set_gravity_dir);
        ClassDB::bind_method(D_METHOD("get_gravity_dir"), &VoxelRenderer::get_gravity_dir);
        ClassDB::bind_method(D_METHOD("set_world_rotation", "rotation"), &VoxelRenderer::set_world_rotation);
        ClassDB::bind_method(D_METHOD("get_world_rotation"), &VoxelRenderer::get_world_rotation);
        ClassDB::bind_method(D_METHOD("set_light_enabled", "enabled"), &VoxelRenderer::set_light_enabled);
        ClassDB::bind_method(D_METHOD("is_light_enabled"), &VoxelRenderer::is_light_enabled);
        ClassDB::bind_method(D_METHOD("set_light_every", "every"), &VoxelRenderer::set_light_every);
        ClassDB::bind_method(D_METHOD("get_light_every"), &VoxelRenderer::get_light_every);
        ClassDB::bind_method(D_METHOD("set_metrics_every", "every"), &VoxelRenderer::set_metrics_every);
        ClassDB::bind_method(D_METHOD("get_metrics_every"), &VoxelRenderer::get_metrics_every);
        ClassDB::bind_method(D_METHOD("set_debug_logging", "enabled"), &VoxelRenderer::set_debug_logging);
        ClassDB::bind_method(D_METHOD("is_debug_logging"), &VoxelRenderer::is_debug_logging);
        ClassDB::bind_method(D_METHOD("set_debug_log_every", "every"), &VoxelRenderer::set_debug_log_every);
        ClassDB::bind_method(D_METHOD("get_debug_log_every"), &VoxelRenderer::get_debug_log_every);
        ClassDB::bind_method(D_METHOD("set_debug_render_thread_ping", "enabled"), &VoxelRenderer::set_debug_render_thread_ping);
        ClassDB::bind_method(D_METHOD("is_debug_render_thread_ping"), &VoxelRenderer::is_debug_render_thread_ping);
        ClassDB::bind_method(D_METHOD("set_debug_probe_enabled", "enabled"), &VoxelRenderer::set_debug_probe_enabled);
        ClassDB::bind_method(D_METHOD("is_debug_probe_enabled"), &VoxelRenderer::is_debug_probe_enabled);
        ClassDB::bind_method(D_METHOD("set_debug_probe_cell", "cell"), &VoxelRenderer::set_debug_probe_cell);
        ClassDB::bind_method(D_METHOD("get_debug_probe_cell"), &VoxelRenderer::get_debug_probe_cell);
        ClassDB::bind_method(D_METHOD("set_debug_probe_every", "every"), &VoxelRenderer::set_debug_probe_every);
        ClassDB::bind_method(D_METHOD("get_debug_probe_every"), &VoxelRenderer::get_debug_probe_every);
        ClassDB::bind_method(D_METHOD("set_sim_enabled", "enabled"), &VoxelRenderer::set_sim_enabled);
        ClassDB::bind_method(D_METHOD("is_sim_enabled"), &VoxelRenderer::is_sim_enabled);
        ClassDB::bind_method(D_METHOD("set_sim_every", "every"), &VoxelRenderer::set_sim_every);
        ClassDB::bind_method(D_METHOD("get_sim_every"), &VoxelRenderer::get_sim_every);
        ClassDB::bind_method(D_METHOD("set_sim_clear_output", "clear"), &VoxelRenderer::set_sim_clear_output);
        ClassDB::bind_method(D_METHOD("is_sim_clear_output"), &VoxelRenderer::is_sim_clear_output);
        ClassDB::bind_method(D_METHOD("set_voxel_entries", "entries", "allocate_all_bricks"), &VoxelRenderer::set_voxel_entries, DEFVAL(false));
        ClassDB::bind_method(D_METHOD("set_debug_probe_cell_xyz", "x", "y", "z"), &VoxelRenderer::set_debug_probe_cell_xyz);
        ClassDB::bind_method(D_METHOD("is_render_ready"), &VoxelRenderer::is_render_ready);
        ClassDB::bind_method(D_METHOD("get_render_debug_state"), &VoxelRenderer::get_render_debug_state);
        ClassDB::bind_method(D_METHOD("debug_rebind_display_texture"), &VoxelRenderer::debug_rebind_display_texture);
        ClassDB::bind_method(D_METHOD("debug_dump_buffers"), &VoxelRenderer::debug_dump_buffers);
        ClassDB::bind_method(D_METHOD("debug_log_state"), &VoxelRenderer::debug_log_state);
        ClassDB::bind_method(D_METHOD("debug_peek_buffers"), &VoxelRenderer::debug_peek_buffers);
        ClassDB::bind_method(D_METHOD("debug_peek_metrics"), &VoxelRenderer::debug_peek_metrics);

        ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "quad_path"), "set_quad_path", "get_quad_path");
        ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "camera_path"), "set_camera_path", "get_camera_path");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "width"), "set_width", "get_width");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "height"), "set_height", "get_height");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "chunk_size"), "set_chunk_size", "get_chunk_size");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "chunk_grid"), "set_chunk_grid", "get_chunk_grid");
        ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lattice_spacing"), "set_lattice_spacing", "get_lattice_spacing");
        ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_distance"), "set_max_distance", "get_max_distance");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_max_distance"), "set_auto_max_distance", "is_auto_max_distance");
        ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fill_radius_ratio"), "set_fill_radius_ratio", "get_fill_radius_ratio");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "fill_mode"), "set_fill_mode", "get_fill_mode");
        ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_threshold"), "set_noise_threshold", "get_noise_threshold");
        ADD_PROPERTY(PropertyInfo(Variant::STRING, "voxel_data_path"), "set_voxel_data_path", "get_voxel_data_path");
        ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity_dir"), "set_gravity_dir", "get_gravity_dir");
        ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "world_rotation"), "set_world_rotation", "get_world_rotation");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "light_enabled"), "set_light_enabled", "is_light_enabled");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "light_every"), "set_light_every", "get_light_every");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "metrics_every"), "set_metrics_every", "get_metrics_every");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_logging"), "set_debug_logging", "is_debug_logging");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_log_every"), "set_debug_log_every", "get_debug_log_every");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_render_thread_ping"), "set_debug_render_thread_ping", "is_debug_render_thread_ping");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "debug_probe_enabled"), "set_debug_probe_enabled", "is_debug_probe_enabled");
        ADD_PROPERTY(PropertyInfo(Variant::VECTOR3I, "debug_probe_cell"), "set_debug_probe_cell", "get_debug_probe_cell");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "debug_probe_every"), "set_debug_probe_every", "get_debug_probe_every");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sim_enabled"), "set_sim_enabled", "is_sim_enabled");
        ADD_PROPERTY(PropertyInfo(Variant::INT, "sim_every"), "set_sim_every", "get_sim_every");
        ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sim_clear_output"), "set_sim_clear_output", "is_sim_clear_output");
}
