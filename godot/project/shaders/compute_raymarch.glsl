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
    vec4 misc;        // x = voxel_size, y = max_dist
    vec4 brick_info;  // xyz = brick grid dims, w = brick size
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

const float ICO_RADIUS = 0.55;

float sdf_icosahedron(vec3 p, float r) {
    const float phi = 1.61803398875;
    const float a = 1.0;
    const float b = 1.0 / phi;
    const float c = phi;
    vec3 n[20] = vec3[20](
        normalize(vec3( a,  a,  a)),
        normalize(vec3( a,  a, -a)),
        normalize(vec3( a, -a,  a)),
        normalize(vec3( a, -a, -a)),
        normalize(vec3(-a,  a,  a)),
        normalize(vec3(-a,  a, -a)),
        normalize(vec3(-a, -a,  a)),
        normalize(vec3(-a, -a, -a)),
        normalize(vec3( 0.0,  b,  c)),
        normalize(vec3( 0.0,  b, -c)),
        normalize(vec3( 0.0, -b,  c)),
        normalize(vec3( 0.0, -b, -c)),
        normalize(vec3( b,  c, 0.0)),
        normalize(vec3( b, -c, 0.0)),
        normalize(vec3(-b,  c, 0.0)),
        normalize(vec3(-b, -c, 0.0)),
        normalize(vec3( c, 0.0,  b)),
        normalize(vec3( c, 0.0, -b)),
        normalize(vec3(-c, 0.0,  b)),
        normalize(vec3(-c, 0.0, -b))
    );

    float d = -1e9;
    for (int i = 0; i < 20; i++) {
        d = max(d, dot(p, n[i]));
    }
    return d - r;
}

vec3 estimate_normal(vec3 p, float r) {
    float e = 0.001;
    float dx = sdf_icosahedron(p + vec3(e, 0.0, 0.0), r) - sdf_icosahedron(p - vec3(e, 0.0, 0.0), r);
    float dy = sdf_icosahedron(p + vec3(0.0, e, 0.0), r) - sdf_icosahedron(p - vec3(0.0, e, 0.0), r);
    float dz = sdf_icosahedron(p + vec3(0.0, 0.0, e), r) - sdf_icosahedron(p - vec3(0.0, 0.0, e), r);
    return normalize(vec3(dx, dy, dz));
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
    vec3 pos = ro + rd * t;
    vec3 local = (pos - grid_min) / u.misc.x;
    ivec3 grid_size = ivec3(int(u.grid_info.x), int(u.grid_info.y), int(u.grid_info.z));
    ivec3 cell = ivec3(floor(local));
    cell = clamp(cell, ivec3(0), grid_size - ivec3(1));

    ivec3 step_dir = ivec3(sign(rd));
    vec3 next_boundary = vec3(
        grid_min.x + (float(cell.x + (step_dir.x > 0 ? 1 : 0)) * u.misc.x),
        grid_min.y + (float(cell.y + (step_dir.y > 0 ? 1 : 0)) * u.misc.x),
        grid_min.z + (float(cell.z + (step_dir.z > 0 ? 1 : 0)) * u.misc.x)
    );
    vec3 t_max = vec3(
        (abs(rd.x) < 1e-6) ? 1e9 : (next_boundary.x - ro.x) / rd.x,
        (abs(rd.y) < 1e-6) ? 1e9 : (next_boundary.y - ro.y) / rd.y,
        (abs(rd.z) < 1e-6) ? 1e9 : (next_boundary.z - ro.z) / rd.z
    );
    vec3 t_delta = vec3(
        (abs(rd.x) < 1e-6) ? 1e9 : (u.misc.x / abs(rd.x)),
        (abs(rd.y) < 1e-6) ? 1e9 : (u.misc.x / abs(rd.y)),
        (abs(rd.z) < 1e-6) ? 1e9 : (u.misc.x / abs(rd.z))
    );

    for (int i = 0; i < 2048; i++) {
        if (!in_bounds(cell) || t > t_exit || t > u.misc.y) {
            break;
        }

        if (((cell.x + cell.y + cell.z) & 1) == 0) {
            ivec3 brick = cell / brick_size;
            uint occ_val = occ.data[idx_brick(brick)];
            if (occ_val != 0u) {
                uint cell_val = atlas.data[atlas_index_for_cell(cell)];
                if (cell_val != 0u) {
                    float t_cell_exit = min(t_max.x, min(t_max.y, t_max.z));
                    float t_cell = max(t, t_enter);
                    vec3 cell_center = (vec3(cell) + vec3(0.5)) * u.misc.x + u.origin.xyz;
                    float max_step = u.misc.x * 0.1;
                    float min_step = u.misc.x * 0.01;
                    for (int j = 0; j < 128; j++) {
                        if (t_cell > t_cell_exit) {
                            break;
                        }
                        vec3 p = ro + rd * t_cell;
                        vec3 lp = (p - cell_center) / u.misc.x;
                        float d = sdf_icosahedron(lp, 0.48);
                        if (d < 0.0) {
                            vec3 n = estimate_normal(lp, 0.48);
                            float diff = max(dot(n, normalize(vec3(-0.6, -1.0, -0.4))), 0.0);
                            color = vec3(0.9, 0.7, 0.4) * (0.2 + diff);
                            hit = true;
                            break;
                        }
                        float sdf_step = d * u.misc.x;
                        sdf_step = clamp(sdf_step, min_step, max_step);
                        t_cell += sdf_step;
                    }
                    if (hit) {
                        break;
                    }
                }
            }
        }

        if (t_max.x < t_max.y) {
            if (t_max.x < t_max.z) {
                t = t_max.x;
                t_max.x += t_delta.x;
                cell.x += step_dir.x;
            } else {
                t = t_max.z;
                t_max.z += t_delta.z;
                cell.z += step_dir.z;
            }
        } else {
            if (t_max.y < t_max.z) {
                t = t_max.y;
                t_max.y += t_delta.y;
                cell.y += step_dir.y;
            } else {
                t = t_max.z;
                t_max.z += t_delta.z;
                cell.z += step_dir.z;
            }
        }
    }

    imageStore(dest, gid, vec4(color, 1.0));
}
