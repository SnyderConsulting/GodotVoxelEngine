#version 450

// Compute per-phase grid velocities for sand and water and apply a simple
// momentum-exchange (drag) coupling between them.
//
// This is a practical approximation of the "multi-species / mixture theory"
// section of the research report, adapted to the project's single-occupancy
// voxel constraint. The intent is:
// - water behaves like water (separate velocity field + pressure projection)
// - sand behaves like sand (separate velocity field, less fluid-like)
// - sand/water exchange momentum near interfaces via drag on shared grid nodes.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std140) uniform Params {
    vec4 grid_info;   // xyz = grid size, w = dt
    vec4 origin;
    vec4 cam_pos;
    vec4 cam_right;
    vec4 cam_up;
    vec4 cam_forward;
    vec4 screen;
    vec4 misc;
    vec4 brick_info;  // xyz = brick grid dims, w = brick size
    vec4 debug_info;  // xyz = gravity dir (grid space), w = gravity strength
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
} u;

layout(set = 0, binding = 1, std430) readonly buffer StaticAtlas {
    uint data[];
} static_atlas;

layout(set = 0, binding = 2, std430) readonly buffer SandOcc {
    uint data[];
} sand_occ;

layout(set = 0, binding = 3, std430) readonly buffer WaterOcc {
    uint data[];
} water_occ;

layout(set = 0, binding = 4, std430) readonly buffer GridAccumSand {
    ivec4 data[];
} grid_accum_sand;

layout(set = 0, binding = 5, std430) readonly buffer GridAccumWater {
    ivec4 data[];
} grid_accum_water;

layout(set = 0, binding = 6, std430) buffer GridVelSand {
    vec4 data[];
} grid_vel_sand;

layout(set = 0, binding = 7, std430) buffer GridVelWater {
    vec4 data[];
} grid_vel_water;

// Drag strength encoded in u.world_rot_y.w (shared Params UBO slot).
// Units are tuned empirically for dt ~= 1/120..1/240.
float drag_strength() {
    return max(0.0, u.world_rot_y.w);
}

bool bcc_parity(ivec3 cell) {
    return ((cell.x & 1) == (cell.y & 1)) && ((cell.y & 1) == (cell.z & 1));
}

bool in_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < int(u.grid_info.x)
        && p.y < int(u.grid_info.y)
        && p.z < int(u.grid_info.z);
}

ivec3 brick_from_index(uint brick_index) {
    uint bx = brick_index % uint(u.brick_info.x);
    uint by = (brick_index / uint(u.brick_info.x)) % uint(u.brick_info.y);
    uint bz = brick_index / (uint(u.brick_info.x) * uint(u.brick_info.y));
    return ivec3(int(bx), int(by), int(bz));
}

ivec3 cell_from_atlas_index(uint atlas_index) {
    uint brick_size = uint(u.brick_info.w);
    uint cells_per_brick = brick_size * brick_size * brick_size;
    uint brick_index = atlas_index / cells_per_brick;
    uint local_index = atlas_index - brick_index * cells_per_brick;
    uint lx = local_index % brick_size;
    uint ly = (local_index / brick_size) % brick_size;
    uint lz = local_index / (brick_size * brick_size);
    ivec3 brick = brick_from_index(brick_index);
    return brick * int(brick_size) + ivec3(int(lx), int(ly), int(lz));
}

uint atlas_index_for_cell_direct(ivec3 cell) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    if (brick.x < 0 || brick.y < 0 || brick.z < 0
        || brick.x >= int(u.brick_info.x)
        || brick.y >= int(u.brick_info.y)
        || brick.z >= int(u.brick_info.z)) {
        return 0xffffffffu;
    }
    uint brick_index = uint(brick.x)
        + uint(brick.y) * uint(u.brick_info.x)
        + uint(brick.z) * uint(u.brick_info.x) * uint(u.brick_info.y);
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

const ivec3 NEIGH[14] = ivec3[14](
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

vec3 apply_solid_bc(ivec3 cell, vec3 v, bool for_water) {
    // Static solids are handled outside; here we only remove velocity components that
    // would flow into neighboring solid voxels (free-slip).
    for (int i = 0; i < 14; i++) {
        ivec3 nc = cell + NEIGH[i];
        if (!in_bounds(nc) || !bcc_parity(nc)) {
            continue;
        }
        uint ni = atlas_index_for_cell_direct(nc);
        if (ni == 0xffffffffu) {
            continue;
        }
        bool solid = static_atlas.data[ni] != 0u;
        if (!solid) {
            if (for_water) {
                solid = sand_occ.data[ni] != 0u;
            } else {
                solid = water_occ.data[ni] != 0u;
            }
        }
        if (!solid) {
            continue;
        }
        vec3 fn = normalize(vec3(NEIGH[i]));
        float toward = dot(v, fn);
        if (toward > 0.0) {
            v -= toward * fn;
        }
    }
    return v;
}

vec3 apply_world_bounds(ivec3 cell, vec3 v) {
    int gx = int(u.grid_info.x);
    int gy = int(u.grid_info.y);
    int gz = int(u.grid_info.z);
    if (cell.x <= 1 && v.x < 0.0) v.x = 0.0;
    if (cell.x >= gx - 2 && v.x > 0.0) v.x = 0.0;
    if (cell.y <= 1 && v.y < 0.0) v.y = 0.0;
    if (cell.y >= gy - 2 && v.y > 0.0) v.y = 0.0;
    if (cell.z <= 1 && v.z < 0.0) v.z = 0.0;
    if (cell.z >= gz - 2 && v.z > 0.0) v.z = 0.0;
    return v;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    uint brick_grid = uint(u.brick_info.x) * uint(u.brick_info.y) * uint(u.brick_info.z);
    uint brick_size = uint(u.brick_info.w);
    uint total = brick_grid * brick_size * brick_size * brick_size;
    if (idx >= total) {
        return;
    }

    ivec3 cell = cell_from_atlas_index(idx);
    if (!bcc_parity(cell)) {
        grid_vel_sand.data[idx] = vec4(0.0);
        grid_vel_water.data[idx] = vec4(0.0);
        return;
    }

    bool is_static = static_atlas.data[idx] != 0u;
    if (is_static) {
        grid_vel_sand.data[idx] = vec4(0.0);
        grid_vel_water.data[idx] = vec4(0.0);
        return;
    }

    ivec4 acc_s = grid_accum_sand.data[idx];
    ivec4 acc_w = grid_accum_water.data[idx];

    int ms_fixed = acc_s.x;
    int mw_fixed = acc_w.x;

    const int MIN_MASS_FIXED = 50; // 0.005 (same rationale as mpm_grid_update.glsl)

    vec3 vs = vec3(0.0);
    vec3 vw = vec3(0.0);
    float ms = 0.0;
    float mw = 0.0;

    if (ms_fixed >= MIN_MASS_FIXED) {
        vs = vec3(acc_s.y, acc_s.z, acc_s.w) / float(ms_fixed);
        ms = float(ms_fixed) / 10000.0;
    }
    if (mw_fixed >= MIN_MASS_FIXED) {
        vw = vec3(acc_w.y, acc_w.z, acc_w.w) / float(mw_fixed);
        mw = float(mw_fixed) / 10000.0;
    }

    float dt = max(0.0, u.grid_info.w);
    vec3 gdir = u.debug_info.xyz;
    float gmag = u.debug_info.w;
    if (length(gdir) < 1e-3) {
        gdir = vec3(0.0, -1.0, 0.0);
    }
    gdir = normalize(gdir);

    if (ms > 0.0) {
        vs += gdir * gmag * dt;
    }
    if (mw > 0.0) {
        vw += gdir * gmag * dt;
    }

    // Drag coupling on nodes where both phases contribute.
    float k = drag_strength();
    if (k > 0.0 && ms > 0.0 && mw > 0.0) {
        vec3 dv = vw - vs;
        float inv_ms = 1.0 / max(ms, 1e-6);
        float inv_mw = 1.0 / max(mw, 1e-6);
        float denom = inv_ms + inv_mw;
        float alpha = clamp(k * dt * denom, 0.0, 1.0);
        vec3 J = (denom > 1e-6) ? ((alpha * dv) / denom) : vec3(0.0);
        // Equal and opposite impulses (conserves total momentum).
        vw -= J * inv_mw;
        vs += J * inv_ms;
    }

    if (ms > 0.0) {
        vs = apply_solid_bc(cell, vs, false);
        vs = apply_world_bounds(cell, vs);
    }
    if (mw > 0.0) {
        vw = apply_solid_bc(cell, vw, true);
        vw = apply_world_bounds(cell, vw);
    }

    // Mild damping and hard clamp for safety.
    if (ms > 0.0) {
        vs *= 0.999;
        float vm = length(vs);
        if (vm > 120.0) {
            vs *= 120.0 / vm;
        }
    }
    if (mw > 0.0) {
        vw *= 0.999;
        float vm = length(vw);
        if (vm > 120.0) {
            vw *= 120.0 / vm;
        }
    }

    grid_vel_sand.data[idx] = vec4(vs, ms);
    grid_vel_water.data[idx] = vec4(vw, mw);
}

