#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D dest;
layout(set = 0, binding = 1, std140) uniform Params {
    vec4 grid_info;   // xyz = grid size
    vec4 origin;      // xyz = grid origin, w = AO radius in cells
    vec4 cam_pos;     // xyz = camera position, w = AO strength
    vec4 cam_right;   // xyz = camera basis right, w = sun dir local x
    vec4 cam_up;      // xyz = camera basis up,    w = sun dir local y
    vec4 cam_forward; // xyz = camera basis fwd,   w = sun dir local z
    vec4 screen;      // xy = screen size, z = tan_half_fov, w = aspect
    vec4 misc;        // x = voxel_size, y = max_dist, z = shadow_strength, w = reflection_strength
    vec4 brick_info;  // xyz = brick grid dims, w = brick size
    vec4 debug_info;  // reserved
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
} u;
layout(set = 0, binding = 2, std430) readonly buffer Indirection {
    uint data[];
} indirection;
layout(set = 0, binding = 3, std430) readonly buffer Atlas {
    uint data[];
} atlas;
layout(set = 0, binding = 4, std430) readonly buffer Occupancy {
    uint data[];
} occ;

layout(set = 0, binding = 5, std430) buffer Metrics {
    uint data[];
} metrics;

layout(set = 0, binding = 6, std430) readonly buffer Light {
    uint data[];
} light_buf;
layout(set = 0, binding = 7, std430) readonly buffer Preview {
    uint data[];
} preview_buf;
layout(set = 0, binding = 8, std430) readonly buffer Cursor {
    uint data[];
} cursor_buf;
layout(set = 0, binding = 9, std430) readonly buffer PreviewOcc {
    uint data[];
} preview_occ;

layout(set = 0, binding = 10, std430) readonly buffer CellPos {
    vec4 data[];
} cell_pos;
layout(set = 0, binding = 11, std430) readonly buffer MaterialProps {
    vec4 data[];
} material_props;

const uint GLASS_MATERIAL = 8u;
const uint INVISIBLE_MATERIAL = 9u;
const uint PREVIEW_MATERIAL = 10u;
const uint CURSOR_MATERIAL = 11u;
const uint FIRE_MATERIAL = 5u;
const uint MATERIAL_PROPS_STRIDE = 5u;

ivec3 nearest_bcc(vec3 p);
bool in_bounds(ivec3 p);
uint atlas_index_for_cell(ivec3 cell);

float sdf_truncated_octahedron(vec3 p) {
    const float inv_sqrt3 = 0.57735026919;
    const float scale = 2.0;
    vec3 q = abs(p) * scale;
    float d1 = max(q.x, max(q.y, q.z)) - 2.0;
    float d2 = (q.x + q.y + q.z - 3.0) * inv_sqrt3;
    return max(d1, d2) / scale;
}

vec3 estimate_normal(vec3 p) {
    float e = 0.001;
    float dx = sdf_truncated_octahedron(p + vec3(e, 0.0, 0.0)) - sdf_truncated_octahedron(p - vec3(e, 0.0, 0.0));
    float dy = sdf_truncated_octahedron(p + vec3(0.0, e, 0.0)) - sdf_truncated_octahedron(p - vec3(0.0, e, 0.0));
    float dz = sdf_truncated_octahedron(p + vec3(0.0, 0.0, e)) - sdf_truncated_octahedron(p - vec3(0.0, 0.0, e));
    return normalize(vec3(dx, dy, dz));
}

vec3 material_color(uint mat_id) {
    const int palette_size = 8;
    vec3 palette[palette_size] = vec3[palette_size](
        vec3(0.90, 0.70, 0.40),
        vec3(0.20, 0.60, 0.90),
        vec3(0.90, 0.30, 0.30),
        vec3(0.30, 0.90, 0.40),
        vec3(0.85, 0.85, 0.20),
        vec3(0.70, 0.40, 0.90),
        vec3(0.40, 0.90, 0.90),
        vec3(0.70, 0.70, 0.70)
    );
    if (mat_id == 0u) {
        return vec3(0.0);
    }
    uint base = mat_id * MATERIAL_PROPS_STRIDE;
    vec3 color = material_props.data[base + 2u].xyz;
    if (max(color.r, max(color.g, color.b)) > 1e-4) {
        return color;
    }
    uint idx = (mat_id - 1u) % uint(palette_size);
    return palette[int(idx)];
}

float material_roughness(uint mat_id) {
    if (mat_id == 0u) {
        return 1.0;
    }
    uint base = mat_id * MATERIAL_PROPS_STRIDE;
    return clamp(material_props.data[base + 2u].w, 0.02, 1.0);
}

vec3 material_emissive(uint mat_id) {
    if (mat_id == 0u) {
        return vec3(0.0);
    }
    uint base = mat_id * MATERIAL_PROPS_STRIDE;
    vec4 e = material_props.data[base + 3u];
    return e.xyz * max(e.w, 0.0);
}

float material_metallic(uint mat_id) {
    if (mat_id == 0u) {
        return 0.0;
    }
    uint base = mat_id * MATERIAL_PROPS_STRIDE;
    return clamp(material_props.data[base + 4u].x, 0.0, 1.0);
}

float material_specular(uint mat_id) {
    if (mat_id == 0u) {
        return 0.5;
    }
    uint base = mat_id * MATERIAL_PROPS_STRIDE;
    return clamp(material_props.data[base + 4u].y, 0.0, 1.0);
}

bool material_blocks_ao(uint mat_id) {
    return mat_id != 0u
        && mat_id != INVISIBLE_MATERIAL
        && mat_id != PREVIEW_MATERIAL
        && mat_id != CURSOR_MATERIAL;
}

float ao_sample(vec3 sample_cell_pos) {
    ivec3 sample_cell = nearest_bcc(sample_cell_pos);
    if (!in_bounds(sample_cell)) {
        return 0.0;
    }
    uint idx = atlas_index_for_cell(sample_cell);
    if (idx == 0u) {
        return 0.0;
    }
    return material_blocks_ao(atlas.data[idx]) ? 1.0 : 0.0;
}

float compute_ao(ivec3 cell, vec3 normal, float radius_cells, float strength) {
    vec3 n = normalize(normal);
    vec3 tangent = normalize(
        (abs(n.y) < 0.99) ? cross(n, vec3(0.0, 1.0, 0.0)) : cross(n, vec3(1.0, 0.0, 0.0))
    );
    vec3 bitangent = normalize(cross(n, tangent));
    vec3 c = vec3(cell);

    float occ = 0.0;
    occ += ao_sample(c + n * (radius_cells * 0.85));
    occ += ao_sample(c + n * (radius_cells * 1.35));
    occ += ao_sample(c + (n + tangent * 0.55) * radius_cells);
    occ += ao_sample(c + (n - tangent * 0.55) * radius_cells);
    occ += ao_sample(c + (n + bitangent * 0.55) * radius_cells);
    occ += ao_sample(c + (n - bitangent * 0.55) * radius_cells);
    occ *= (1.0 / 6.0);

    float ao = 1.0 - clamp(occ * strength, 0.0, 1.0);
    return clamp(ao * ao, 0.0, 1.0);
}

vec3 aces_film(vec3 x) {
    // ACES-inspired fit by Krzysztof Narkowicz.
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

float distance_fog(float distance_to_hit, float density) {
    return 1.0 - exp(-max(distance_to_hit, 0.0) * max(density, 0.0));
}

float height_fog(float distance_to_hit, float ray_origin_height, float ray_dir_y, float density, float falloff) {
    // Exponential height fog integral form adapted from IQ's fog notes.
    float b = max(1e-4, falloff);
    float a = max(density, 0.0);
    float h0 = max(ray_origin_height, 0.0);
    if (abs(ray_dir_y) < 1e-4) {
        return clamp(a * distance_to_hit * exp(-h0 * b), 0.0, 1.0);
    }
    float fog_amount = (a / b) * exp(-h0 * b) * (1.0 - exp(-distance_to_hit * ray_dir_y * b)) / ray_dir_y;
    return clamp(max(fog_amount, 0.0), 0.0, 1.0);
}

void clip_plane(vec3 n, float d, vec3 rc, vec3 rd, inout float tmin, inout float tmax, inout bool valid) {
    float denom = dot(n, rd);
    float numer = d - dot(n, rc);
    if (abs(denom) < 1e-6) {
        if (numer < 0.0) {
            valid = false;
        }
        return;
    }
    float tplane = numer / denom;
    if (denom < 0.0) {
        tmin = max(tmin, tplane);
    } else {
        tmax = min(tmax, tplane);
    }
    if (tmin > tmax) {
        valid = false;
    }
}

bool bcc_parity(ivec3 cell) {
    return ((cell.x & 1) == (cell.y & 1)) && ((cell.y & 1) == (cell.z & 1));
}

ivec3 nearest_bcc(vec3 p) {
    ivec3 base = ivec3(floor(p));
    ivec3 best = base;
    float best_dist = 1e9;
    for (int dz = 0; dz <= 1; dz++) {
        for (int dy = 0; dy <= 1; dy++) {
            for (int dx = 0; dx <= 1; dx++) {
                ivec3 cand = base + ivec3(dx, dy, dz);
                if (!bcc_parity(cand)) {
                    continue;
                }
                float dist = length(p - vec3(cand));
                if (dist < best_dist) {
                    best_dist = dist;
                    best = cand;
                }
            }
        }
    }
    return best;
}

uint idx_brick(ivec3 b) {
    return uint(b.x) + uint(b.y) * uint(u.brick_info.x)
        + uint(b.z) * uint(u.brick_info.x) * uint(u.brick_info.y);
}

bool in_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < int(u.grid_info.x)
        && p.y < int(u.grid_info.y)
        && p.z < int(u.grid_info.z);
}

bool brick_in_bounds(ivec3 b) {
    return b.x >= 0 && b.y >= 0 && b.z >= 0
        && b.x < int(u.brick_info.x)
        && b.y < int(u.brick_info.y)
        && b.z < int(u.brick_info.z);
}

uint atlas_index_for_cell(ivec3 cell) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    uint ind = indirection.data[idx_brick(brick)];
    if (ind == 0u) {
        return 0u;
    }
    uint brick_index = ind - 1u;
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

uint light_at_cell(ivec3 cell) {
    return light_buf.data[atlas_index_for_cell(cell)];
}

float light_factor_for_voxel(ivec3 cell) {
    float sum_light = float(light_at_cell(cell)) * 4.0;
    float sum_weight = 4.0;
    ivec3 offsets[14] = ivec3[14](
        ivec3(2, 0, 0),
        ivec3(-2, 0, 0),
        ivec3(0, 2, 0),
        ivec3(0, -2, 0),
        ivec3(0, 0, 2),
        ivec3(0, 0, -2),
        ivec3(1, 1, 1),
        ivec3(1, 1, -1),
        ivec3(1, -1, 1),
        ivec3(1, -1, -1),
        ivec3(-1, 1, 1),
        ivec3(-1, 1, -1),
        ivec3(-1, -1, 1),
        ivec3(-1, -1, -1)
    );
    for (int n = 0; n < 14; n++) {
        ivec3 neighbor = cell + offsets[n];
        if (!in_bounds(neighbor)) {
            continue;
        }
        sum_light += float(light_at_cell(neighbor));
        sum_weight += 1.0;
    }
    float lf = sum_light / max(sum_weight, 1.0);
    return clamp(lf / 15.0, 0.0, 1.0);
}

void main() {
    ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
    int width = int(u.screen.x);
    int height = int(u.screen.y);
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(width, height);
    vec2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;

    vec3 ro = u.cam_pos.xyz;
    vec3 rd = normalize(
        u.cam_forward.xyz +
        u.cam_right.xyz * (ndc.x * u.screen.w * u.screen.z) +
        u.cam_up.xyz * (ndc.y * u.screen.z)
    );

    vec3 grid_min = u.origin.xyz;
    vec3 grid_max = grid_min + u.grid_info.xyz * u.misc.x;
    mat3 world_rot = mat3(u.world_rot_x.xyz, u.world_rot_y.xyz, u.world_rot_z.xyz);
    mat3 inv_world = transpose(world_rot);
    vec3 world_center = (grid_min + grid_max) * 0.5;
    ro = world_center + inv_world * (ro - world_center);
    rd = normalize(inv_world * rd);

    vec3 sun_dir_local = vec3(u.cam_right.w, u.cam_up.w, u.cam_forward.w);
    if (length(sun_dir_local) < 1e-4) {
        sun_dir_local = normalize(vec3(0.45, -0.85, 0.30));
    } else {
        sun_dir_local = normalize(sun_dir_local);
    }
    vec3 light_dir = normalize(-sun_dir_local);
    float sky = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 sky_low = vec3(0.10, 0.11, 0.12);
    vec3 sky_horizon = vec3(0.33, 0.38, 0.44);
    vec3 sky_high = vec3(0.14, 0.27, 0.45);
    vec3 sky_color = mix(sky_low, sky_horizon, smoothstep(-0.25, 0.25, rd.y));
    sky_color = mix(sky_color, sky_high, smoothstep(0.1, 1.0, sky));
    float sun_amount = max(dot(rd, light_dir), 0.0);
    float sun_halo = pow(sun_amount, 24.0);
    float sun_disk = pow(sun_amount, 320.0);
    sky_color += vec3(0.95, 0.68, 0.35) * sun_halo * 0.16;
    sky_color += vec3(1.00, 0.92, 0.80) * sun_disk * 0.40;
    vec3 color = sky_color;
    vec3 overlay_color = vec3(0.0);
    float overlay_alpha = 0.0;
    bool hit = false;
    float hit_distance = 0.0;
    vec3 hit_position = ro;
    uint step_count = 0u;
    atomicAdd(metrics.data[0], 1u);
    int brick_size = int(u.brick_info.w);

    vec3 inv_dir = vec3(
        (abs(rd.x) < 1e-6) ? 1e9 : (1.0 / rd.x),
        (abs(rd.y) < 1e-6) ? 1e9 : (1.0 / rd.y),
        (abs(rd.z) < 1e-6) ? 1e9 : (1.0 / rd.z)
    );
    vec3 t0 = (grid_min - ro) * inv_dir;
    vec3 t1 = (grid_max - ro) * inv_dir;
    vec3 tmin3 = min(t0, t1);
    vec3 tmax3 = max(t0, t1);
    float t_enter = max(tmin3.x, max(tmin3.y, tmin3.z));
    float t_exit = min(tmax3.x, min(tmax3.y, tmax3.z));
    if (t_exit <= max(t_enter, 0.0)) {
        imageStore(dest, gid, vec4(color, 1.0));
        return;
    }

    const int MAX_STEPS = 2048;
    const int MAX_BRICK_STEPS = 1024;
    bool cam_inside_grid = all(greaterThanEqual(ro, grid_min)) && all(lessThanEqual(ro, grid_max));
    int max_steps_runtime = cam_inside_grid ? 1024 : MAX_STEPS;
    int max_brick_steps_runtime = cam_inside_grid ? 512 : MAX_BRICK_STEPS;
    int sdf_steps_runtime = cam_inside_grid ? 56 : 96;
    int shadow_steps_runtime = cam_inside_grid ? 8 : 24;
    float base_step = (cam_inside_grid ? 0.03 : 0.015) * u.misc.x;
    float empty_step = max(base_step, (t_exit - max(t_enter, 0.0)) / float(MAX_STEPS));
    vec3 ro_cell = (ro - grid_min) / u.misc.x;
    vec3 rd_cell = rd / u.misc.x;
    float t = max(t_enter, 0.0) + 1e-4;
    vec3 pos_cell = ro_cell + rd_cell * t;
    ivec3 brick_grid = ivec3(int(u.brick_info.x), int(u.brick_info.y), int(u.brick_info.z));
    ivec3 brick = ivec3(floor(pos_cell / float(brick_size)));
    ivec3 step = ivec3(
        (rd_cell.x > 0.0) ? 1 : ((rd_cell.x < 0.0) ? -1 : 0),
        (rd_cell.y > 0.0) ? 1 : ((rd_cell.y < 0.0) ? -1 : 0),
        (rd_cell.z > 0.0) ? 1 : ((rd_cell.z < 0.0) ? -1 : 0)
    );
    vec3 next_boundary = vec3(
        (step.x > 0) ? (float(brick.x + 1) * float(brick_size)) : (float(brick.x) * float(brick_size)),
        (step.y > 0) ? (float(brick.y + 1) * float(brick_size)) : (float(brick.y) * float(brick_size)),
        (step.z > 0) ? (float(brick.z + 1) * float(brick_size)) : (float(brick.z) * float(brick_size))
    );
    vec3 tMax = vec3(
        (step.x != 0) ? (next_boundary.x - pos_cell.x) / rd_cell.x + t : 1e9,
        (step.y != 0) ? (next_boundary.y - pos_cell.y) / rd_cell.y + t : 1e9,
        (step.z != 0) ? (next_boundary.z - pos_cell.z) / rd_cell.z + t : 1e9
    );
    vec3 tDelta = vec3(
        (step.x != 0) ? float(brick_size) / abs(rd_cell.x) : 1e9,
        (step.y != 0) ? float(brick_size) / abs(rd_cell.y) : 1e9,
        (step.z != 0) ? float(brick_size) / abs(rd_cell.z) : 1e9
    );
    vec3 signs[8] = vec3[8](
        vec3( 1.0,  1.0,  1.0),
        vec3( 1.0,  1.0, -1.0),
        vec3( 1.0, -1.0,  1.0),
        vec3( 1.0, -1.0, -1.0),
        vec3(-1.0,  1.0,  1.0),
        vec3(-1.0,  1.0, -1.0),
        vec3(-1.0, -1.0,  1.0),
        vec3(-1.0, -1.0, -1.0)
    );

    for (int b = 0; b < MAX_BRICK_STEPS; b++) {
        if (b >= max_brick_steps_runtime) {
            break;
        }
        step_count++;
        if (t > t_exit || t > u.misc.y) {
            break;
        }
        if (brick.x < 0 || brick.y < 0 || brick.z < 0 ||
            brick.x >= brick_grid.x || brick.y >= brick_grid.y || brick.z >= brick_grid.z) {
            break;
        }
        float t_brick_exit = min(tMax.x, min(tMax.y, tMax.z));
        float t_brick_limit = min(t_brick_exit + 1.5 * u.misc.x, t_exit);
        uint occ_val = occ.data[idx_brick(brick)];
        bool brick_active = occ_val != 0u || preview_occ.data[idx_brick(brick)] != 0u;
        if (!brick_active) {
            for (int dz = -1; dz <= 1 && !brick_active; dz++) {
                for (int dy = -1; dy <= 1 && !brick_active; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        ivec3 nb = brick + ivec3(dx, dy, dz);
                        if (!brick_in_bounds(nb)) {
                            continue;
                        }
                        if (occ.data[idx_brick(nb)] != 0u || preview_occ.data[idx_brick(nb)] != 0u) {
                            brick_active = true;
                            break;
                        }
                    }
                }
            }
        }
        if (brick_active) {
            float t_cell = t;
            for (int i = 0; i < MAX_STEPS; i++) {
                if (i >= max_steps_runtime) {
                    break;
                }
                step_count++;
                if (t_cell > t_brick_limit || t_cell > u.misc.y) {
                    break;
                }
                vec3 pos = ro + rd * t_cell;
                vec3 local = (pos - grid_min) / u.misc.x;
                ivec3 cell = nearest_bcc(local);
                if (!in_bounds(cell)) {
                    t_cell += empty_step;
                    continue;
                }
                ivec3 cell_brick = cell / brick_size;
                uint cell_occ = occ.data[idx_brick(cell_brick)];
                uint atlas_index = atlas_index_for_cell(cell);
                if (atlas_index == 0u) {
                    t_cell += empty_step;
                    continue;
                }
                uint cell_val = atlas.data[atlas_index];
                uint preview_val = preview_buf.data[atlas_index];
                uint cursor_val = cursor_buf.data[atlas_index];
                if (cell_val == INVISIBLE_MATERIAL) {
                    t_cell += empty_step;
                    continue;
                }
                if (cell_occ != 0u || preview_val != 0u || cursor_val != 0u) {
                    if (cell_val != 0u || preview_val != 0u || cursor_val != 0u) {
                        bool glass_cell = cell_val == GLASS_MATERIAL;
                        bool preview_cell = (cell_val == 0u && preview_val != 0u && cursor_val == 0u);
                        bool cursor_cell = (cell_val == 0u && cursor_val != 0u);
                        vec3 cell_center = u.origin.xyz + vec3(cell) * u.misc.x;
                        vec3 center = cell_center;
                        vec4 ppos = cell_pos.data[atlas_index];
                        if (ppos.w > 0.5 && !glass_cell && !preview_cell && !cursor_cell) {
                            center = u.origin.xyz + ppos.xyz * u.misc.x;
                        }
                        vec3 rc = ro - center;
                        float a = u.misc.x;
                        float t_cell_min = -1e9;
                        float t_cell_max = 1e9;
                        bool valid = true;

                        clip_plane(vec3( 1.0,  0.0,  0.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        clip_plane(vec3(-1.0,  0.0,  0.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        clip_plane(vec3( 0.0,  1.0,  0.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        clip_plane(vec3( 0.0, -1.0,  0.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        clip_plane(vec3( 0.0,  0.0,  1.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        clip_plane(vec3( 0.0,  0.0, -1.0), a, rc, rd, t_cell_min, t_cell_max, valid);
                        for (int s = 0; s < 8; s++) {
                            clip_plane(signs[s], 1.5 * a, rc, rd, t_cell_min, t_cell_max, valid);
                        }

                        if (valid) {
                            float t_voxel = max(t_cell, t_cell_min);
                            float max_step = a * 0.1;
                            float min_step = a * 0.01;
                            bool glass_hit = false;
                            float t_prev = t_voxel;
                            vec3 p_prev = ro + rd * t_prev;
                            vec3 lp_prev = (p_prev - center) / a;
                            float d_prev = sdf_truncated_octahedron(lp_prev) * a;
                            if (d_prev < 0.0) {
                                t_prev = max(t_cell_min, t_prev - min_step);
                                p_prev = ro + rd * t_prev;
                                lp_prev = (p_prev - center) / a;
                                d_prev = sdf_truncated_octahedron(lp_prev) * a;
                            }
                            for (int j = 0; j < 128; j++) {
                                if (j >= sdf_steps_runtime) {
                                    break;
                                }
                                step_count++;
                                if (t_voxel > t_cell_max) {
                                    break;
                                }
                                vec3 p = ro + rd * t_voxel;
                                vec3 lp = (p - center) / a;
                                float d = sdf_truncated_octahedron(lp) * a;     
                                if (d < 0.0) {
                                    if (d_prev > 0.0 && (t_voxel - t_prev) > 1e-5) {
                                        float ta = t_prev;
                                        float tb = t_voxel;
                                        for (int r = 0; r < 4; r++) {
                                            float tm = 0.5 * (ta + tb);
                                            vec3 pm = ro + rd * tm;
                                            vec3 lpm = (pm - center) / a;
                                            float dm = sdf_truncated_octahedron(lpm) * a;
                                            if (dm < 0.0) {
                                                tb = tm;
                                            } else {
                                                ta = tm;
                                            }
                                        }
                                        t_voxel = tb;
                                        p = ro + rd * t_voxel;
                                        lp = (p - center) / a;
                                        d = sdf_truncated_octahedron(lp) * a;
                                    }
                                    if (glass_cell || preview_cell || cursor_cell) {
                                        float edge = 1.0 - smoothstep(0.0, 0.02 * a, abs(d));
                                        if (edge > 0.0) {
                                            overlay_alpha = max(overlay_alpha, edge * 0.5);
                                            overlay_color = cursor_cell ? vec3(0.0, 1.0, 0.6) : (preview_cell ? vec3(0.05, 0.9, 0.2) : vec3(0.05));
                                        }
                                        glass_hit = true;
                                        t_voxel += max(abs(d), min_step);
                                        continue;
                                    }
                                    vec3 n = estimate_normal(lp);
                                    vec3 hit_pos = ro + rd * t_voxel;
                                    float diff = max(dot(n, light_dir), 0.0);
                                    float ao_strength = max(u.cam_pos.w, 0.0);
                                    float ao = 1.0;

                                    // Soft shadow ray
                                    float shadow = 1.0;
                                    vec3 shadow_origin = hit_pos + n * (a * 0.05);
                                    float t_shadow = a * 0.08;
                                    for (int s = 0; s < 24; s++) {
                                        if (s >= shadow_steps_runtime) {
                                            break;
                                        }
                                        vec3 sp = shadow_origin + light_dir * t_shadow;
                                        vec3 s_local = (sp - grid_min) / u.misc.x;
                                        ivec3 s_cell = nearest_bcc(s_local);
                                        if (!in_bounds(s_cell)) {
                                            break;
                                        }
                                        if (bcc_parity(s_cell)) {
                                            ivec3 s_brick = s_cell / brick_size;
                                            if (occ.data[idx_brick(s_brick)] != 0u) {
                                                uint s_val = atlas.data[atlas_index_for_cell(s_cell)];
                                                if (s_val != 0u
                                                    && s_val != GLASS_MATERIAL
                                                    && s_val != INVISIBLE_MATERIAL
                                                    && s_val != FIRE_MATERIAL) {
                                                    vec3 s_center = u.origin.xyz + vec3(s_cell) * u.misc.x;
                                                    vec3 s_lp = (sp - s_center) / u.misc.x;
                                                    float sd = sdf_truncated_octahedron(s_lp) * u.misc.x;
                                                    if (sd < 0.0) {
                                                        shadow = 0.0;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        t_shadow += a * 0.22;
                                    }
                                    shadow = mix(1.0, shadow, clamp(u.misc.z, 0.0, 1.0));

                                    vec3 view_dir = normalize(-rd);
                                    vec3 base = material_color(cell_val);
                                    float roughness = material_roughness(cell_val);
                                    float metallic = material_metallic(cell_val);
                                    float specular_level = material_specular(cell_val);
                                    vec3 half_dir = normalize(light_dir + view_dir);
                                    float spec_power = mix(96.0, 10.0, roughness * roughness);
                                    float spec = pow(max(dot(n, half_dir), 0.0), spec_power);

                                    float light_factor = 1.0;
                                    float ambient = 0.11;
                                    float ndot_up = clamp(n.y * 0.5 + 0.5, 0.0, 1.0);
                                    vec3 hemi_sky = vec3(0.30, 0.36, 0.44);
                                    vec3 hemi_ground = vec3(0.12, 0.10, 0.08);
                                    vec3 ambient_tint = mix(hemi_ground, hemi_sky, ndot_up);
                                    float ao_mix = 0.0;
                                    vec3 ambient_color = ambient_tint * (ambient * mix(1.0, ao, ao_mix));
                                    float diffuse = diff * shadow;
                                    float fill = 0.035;
                                    float specular = spec * shadow * mix(0.22, 0.03, roughness) * 0.9;

                                    float dielectric_f0 = mix(0.02, 0.10, specular_level);
                                    vec3 f0 = mix(vec3(dielectric_f0), base, metallic);
                                    float view_half = clamp(dot(view_dir, half_dir), 0.0, 1.0);
                                    vec3 fresnel_term = f0 + (vec3(1.0) - f0) * pow(1.0 - view_half, 5.0);
                                    float diffuse_energy = (1.0 - metallic)
                                        * (1.0 - clamp((f0.r + f0.g + f0.b) * (1.0 / 3.0), 0.0, 0.9));
                                    float reflection_scale = (1.0 - roughness * 0.7)
                                        * (0.35 + 0.65 * specular_level)
                                        * mix(1.0, 1.3, metallic);
                                    vec3 refl_dir = reflect(rd, n);
                                    float refl_sky = clamp(refl_dir.y * 0.5 + 0.5, 0.0, 1.0);
                                    vec3 env_color = mix(sky_low, sky_horizon, smoothstep(-0.25, 0.25, refl_dir.y));
                                    env_color = mix(env_color, sky_high, smoothstep(0.1, 1.0, refl_sky));
                                    float env_sun = pow(max(dot(refl_dir, light_dir), 0.0), mix(96.0, 12.0, roughness));
                                    env_color += vec3(1.0, 0.92, 0.80) * env_sun * (0.08 + 0.22 * (1.0 - roughness));
                                    vec3 ibl = env_color * fresnel_term * reflection_scale * clamp(u.misc.w, 0.0, 1.0);

                                    color = base * (ambient_color + (diffuse + fill) * diffuse_energy)
                                        + fresnel_term * specular
                                        + ibl;
                                    vec3 emissive = material_emissive(cell_val);
                                    if (cell_val == FIRE_MATERIAL && max(emissive.r, max(emissive.g, emissive.b)) > 0.0) {
                                        float flicker = 0.85 + 0.15 * fract(
                                            sin(dot(vec3(cell), vec3(12.9898, 78.233, 37.719))) * 43758.5453
                                        );
                                        emissive *= (1.25 + 0.75 * flicker);
                                    }
                                    color += emissive;
                                    hit = true;
                                    hit_distance = t_voxel;
                                    hit_position = hit_pos;
                                    atomicAdd(metrics.data[1], 1u);
                                    break;
                                }
                                float sdf_step = clamp(d, min_step, max_step);  
                                t_prev = t_voxel;
                                d_prev = d;
                                t_voxel += sdf_step;
                            }
                            if (glass_cell && glass_hit) {
                                t_cell = t_cell_max + 0.0005;
                                continue;
                            }
                            if (hit) {
                                break;
                            }
                            t_cell = t_cell_max + 0.0005;
                            continue;
                        }
                    }
                }
                t_cell += empty_step;
            }
            if (hit) {
                break;
            }
        }

        if (tMax.x < tMax.y) {
            if (tMax.x < tMax.z) {
                brick.x += step.x;
                t = tMax.x;
                tMax.x += tDelta.x;
            } else {
                brick.z += step.z;
                t = tMax.z;
                tMax.z += tDelta.z;
            }
        } else {
            if (tMax.y < tMax.z) {
                brick.y += step.y;
                t = tMax.y;
                tMax.y += tDelta.y;
            } else {
                brick.z += step.z;
                t = tMax.z;
                tMax.z += tDelta.z;
            }
        }
        t += 1e-4;
    }

    atomicAdd(metrics.data[2], step_count);
    if (hit) {
        float fog_dist = hit_distance;
        float ray_origin_height = ro.y - grid_min.y;
        float fog_a = distance_fog(fog_dist, 0.02);
        float fog_b = height_fog(fog_dist, ray_origin_height, rd.y, 0.06, 0.05);
        float height_factor = smoothstep(0.0, u.grid_info.y * u.misc.x, hit_position.y - grid_min.y);
        float fog_amount = clamp(max(fog_a * (1.0 - 0.35 * height_factor), fog_b), 0.0, 0.92);
        color = mix(color, sky_color, fog_amount);
    }
    color = aces_film(max(color, vec3(0.0)));
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = mix(vec3(luma), color, 1.06);
    float dither = fract(sin(dot(vec2(gid), vec2(12.9898, 78.233))) * 43758.5453);
    color += vec3((dither - 0.5) / 255.0);
    color = mix(color, overlay_color, clamp(overlay_alpha, 0.0, 1.0));
    imageStore(dest, gid, vec4(clamp(color, 0.0, 1.0), 1.0));
}
