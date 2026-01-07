#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D dest;
layout(set = 0, binding = 1, std140) uniform Params {
    vec4 grid_info;   // xyz = grid size
    vec4 origin;      // xyz = grid origin
    vec4 cam_pos;
    vec4 cam_right;
    vec4 cam_up;
    vec4 cam_forward;
    vec4 screen;      // xy = screen size, z = tan_half_fov, w = aspect
    vec4 misc;        // x = voxel_size, y = max_dist, z = shadow_strength, w = reflection_strength
    vec4 brick_info;  // xyz = brick grid dims, w = brick size
    vec4 debug_info;  // reserved
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
    uint idx = (mat_id - 1u) % uint(palette_size);
    return palette[int(idx)];
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

uint light_for_voxel(ivec3 cell) {
    uint max_light = light_at_cell(cell);
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
        uint n_light = light_at_cell(neighbor);
        if (n_light > max_light) {
            max_light = n_light;
        }
    }
    return max_light;
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

    vec3 color = vec3(0.12);
    bool hit = false;
    uint step_count = 0u;
    atomicAdd(metrics.data[0], 1u);
    int brick_size = int(u.brick_info.w);

    vec3 grid_min = u.origin.xyz;
    vec3 grid_max = grid_min + u.grid_info.xyz * u.misc.x;

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

    const int MAX_STEPS = 4096;
    const int MAX_BRICK_STEPS = 2048;
    float base_step = 0.01 * u.misc.x;
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
        bool brick_active = occ_val != 0u;
        if (!brick_active) {
            for (int dz = -1; dz <= 1 && !brick_active; dz++) {
                for (int dy = -1; dy <= 1 && !brick_active; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        ivec3 nb = brick + ivec3(dx, dy, dz);
                        if (!brick_in_bounds(nb)) {
                            continue;
                        }
                        if (occ.data[idx_brick(nb)] != 0u) {
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
                if (cell_occ != 0u) {
                    uint cell_val = atlas.data[atlas_index_for_cell(cell)];
                    if (cell_val != 0u) {
                        vec3 cell_center = u.origin.xyz + vec3(cell) * u.misc.x;
                        vec3 rc = ro - cell_center;
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
                            for (int j = 0; j < 128; j++) {
                                step_count++;
                                if (t_voxel > t_cell_max) {
                                    break;
                                }
                                vec3 p = ro + rd * t_voxel;
                                vec3 lp = (p - cell_center) / a;
                                float d = sdf_truncated_octahedron(lp) * a;
                                if (d < 0.0) {
                                    vec3 n = estimate_normal(lp);
                                    vec3 hit_pos = ro + rd * t_voxel;
                                    vec3 light_dir = normalize(u.cam_pos.xyz - hit_pos);
                                    float diff = max(dot(n, light_dir), 0.0);

                                    // Soft shadow ray
                                    float shadow = 1.0;
                                    float t_shadow = 0.02;
                                    for (int s = 0; s < 24; s++) {
                                        vec3 sp = hit_pos + light_dir * t_shadow;
                                        vec3 s_local = (sp - grid_min) / u.misc.x;
                                        ivec3 s_cell = nearest_bcc(s_local);
                                        if (!in_bounds(s_cell)) {
                                            break;
                                        }
                                        if (bcc_parity(s_cell)) {
                                            ivec3 s_brick = s_cell / brick_size;
                                            if (occ.data[idx_brick(s_brick)] != 0u) {
                                                uint s_val = atlas.data[atlas_index_for_cell(s_cell)];
                                                if (s_val != 0u) {
                                                    vec3 s_center = u.origin.xyz + vec3(s_cell) * u.misc.x;
                                                    vec3 s_lp = (sp - s_center) / u.misc.x;
                                                    float sd = sdf_truncated_octahedron(s_lp) * u.misc.x;
                                                    if (sd < 0.0) {
                                                        shadow = 0.0;
                                                        break;
                                                    }
                                                    shadow = min(shadow, 10.0 * sd / t_shadow);
                                                }
                                            }
                                        }
                                        t_shadow += 0.06;
                                    }
                                    shadow = mix(1.0, shadow, clamp(u.misc.z, 0.0, 1.0));

                                    // Reflection ray (single bounce)
                                    float reflection = 0.0;
                                    vec3 refl_dir = reflect(rd, n);
                                    float t_refl = 0.05;
                                    for (int r = 0; r < 16; r++) {
                                        vec3 rp = hit_pos + refl_dir * t_refl;
                                        vec3 r_local = (rp - grid_min) / u.misc.x;
                                        ivec3 r_cell = nearest_bcc(r_local);
                                        if (!in_bounds(r_cell)) {
                                            break;
                                        }
                                        if (bcc_parity(r_cell)) {
                                            ivec3 r_brick = r_cell / brick_size;
                                            if (occ.data[idx_brick(r_brick)] != 0u) {
                                                uint r_val = atlas.data[atlas_index_for_cell(r_cell)];
                                                if (r_val != 0u) {
                                                    vec3 r_center = u.origin.xyz + vec3(r_cell) * u.misc.x;
                                                    vec3 r_lp = (rp - r_center) / u.misc.x;
                                                    float rdv = sdf_truncated_octahedron(r_lp) * u.misc.x;
                                                    if (rdv < 0.0) {
                                                        reflection = u.misc.w;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        t_refl += 0.08;
                                    }

                            vec3 view_dir = normalize(-rd);
                            vec3 half_dir = normalize(light_dir + view_dir);
                            float spec = pow(max(dot(n, half_dir), 0.0), 32.0);

                            uint light_val = light_for_voxel(cell);
                            float light_factor = float(light_val) / 15.0;
                            float ambient = mix(0.06, 0.28, light_factor);
                            float diffuse = diff * shadow * mix(0.2, 1.0, light_factor);
                            vec3 base = material_color(cell_val);
                            color = base * (ambient + diffuse) + base * reflection * light_factor + vec3(1.0) * spec * 0.25 * light_factor;
                                    hit = true;
                                    atomicAdd(metrics.data[1], 1u);
                                    break;
                                }
                                float sdf_step = clamp(d, min_step, max_step);
                                t_voxel += sdf_step;
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
    imageStore(dest, gid, vec4(color, 1.0));
}
