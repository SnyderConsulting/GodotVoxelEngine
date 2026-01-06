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
    vec4 debug_info;  // x = debug overlay toggle
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

    if (u.debug_info.x > 0.5) {
        int bricks_x = int(u.brick_info.x);
        int bricks_y = int(u.brick_info.y);
        int bricks_z = int(u.brick_info.z);
        int bx = clamp(int(floor(uv.x * float(bricks_x))), 0, bricks_x - 1);
        int by = clamp(int(floor(uv.y * float(bricks_y))), 0, bricks_y - 1);
        int bz = bricks_z / 2;
        uint occ_val = occ.data[idx_brick(ivec3(bx, by, bz))];
        vec3 dbg = (occ_val != 0u) ? vec3(0.1, 0.8, 0.2) : vec3(0.15);
        imageStore(dest, gid, vec4(dbg, 1.0));
        return;
    }
    vec3 ro = u.cam_pos.xyz;
    vec3 rd = normalize(
        u.cam_forward.xyz +
        u.cam_right.xyz * (ndc.x * u.screen.w * u.screen.z) +
        u.cam_up.xyz * (ndc.y * u.screen.z)
    );

    vec3 color = vec3(0.12);
    bool hit = false;
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

    float t = max(t_enter, 0.0);
    ivec3 grid_size = ivec3(int(u.grid_info.x), int(u.grid_info.y), int(u.grid_info.z));
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

    for (int i = 0; i < 2048; i++) {
        if (t > t_exit || t > u.misc.y) {
            break;
        }

        vec3 pos = ro + rd * t;
        vec3 local = (pos - grid_min) / u.misc.x;
        ivec3 cell = nearest_bcc(local);
        if (!in_bounds(cell)) {
            t += 0.01;
            continue;
        }

        ivec3 brick = cell / brick_size;
        uint occ_val = occ.data[idx_brick(brick)];
        if (occ_val != 0u) {
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
                    float t_cell = max(t, t_cell_min);
                    float max_step = a * 0.1;
                    float min_step = a * 0.01;
                    for (int j = 0; j < 128; j++) {
                        if (t_cell > t_cell_max) {
                            break;
                        }
                        vec3 p = ro + rd * t_cell;
                        vec3 lp = (p - cell_center) / a;
                        float d = sdf_truncated_octahedron(lp) * a;
                        if (d < 0.0) {
                            vec3 n = estimate_normal(lp);
                            vec3 hit_pos = ro + rd * t_cell;
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

                            vec3 base = vec3(0.9, 0.7, 0.4);
                            color = base * (0.12 + diff * shadow) + base * reflection + vec3(1.0) * spec * 0.25;
                            hit = true;
                            break;
                        }
                        float sdf_step = clamp(d, min_step, max_step);
                        t_cell += sdf_step;
                    }
                    if (hit) {
                        break;
                    }
                    t = t_cell_max + 0.0005;
                    continue;
                }
            }
        }

        t += 0.01;
    }

    imageStore(dest, gid, vec4(color, 1.0));
}
