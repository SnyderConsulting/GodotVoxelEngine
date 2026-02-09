#version 450

// Lightweight per-frame GPU stats for autonomous testing and regression detection.
// Uses fixed-point/int atomics to avoid requiring atomic float extensions.

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

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
    vec4 debug_info;
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
} u;

layout(set = 0, binding = 1, std430) readonly buffer Indirection {
    uint data[];
} indirection;

layout(set = 0, binding = 2, std430) readonly buffer StaticAtlas {
    uint data[];
} static_atlas;

layout(set = 0, binding = 3, std430) readonly buffer ParticlePosMass {
    vec4 data[];
} pos_mass;

layout(set = 0, binding = 4, std430) readonly buffer ParticleVelVol {
    vec4 data[];
} vel_vol;

layout(set = 0, binding = 5, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 6, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 7, std430) buffer StatsOut {
    int data[];
} stats_out;

const int MAT_SLOTS = 16;
const float MASS_FP = 10000.0;
const float SPEED_SUM_FP = 100.0;
const float SPEED_MAX_FP = 1000.0;
const float POS_FP = 1000.0;
const float MPOS_FP = 100.0;

// Header
const int IDX_PARTICLE_COUNT = 1;
const int IDX_ACTIVE_COUNT = 2;
const int IDX_INACTIVE_COUNT = 3;
const int IDX_NAN_COUNT = 4;
const int IDX_BASE = 5;

// Per-slot block (ints)
// [count, mass_sum_fixed, sum_speed_x100, max_speed_x1000, overlap_static,
//  min_x,min_y,min_z, max_x,max_y,max_z, sum_mx,sum_my,sum_mz]
const int SLOT_STRIDE = 14;

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

bool bcc_parity(ivec3 cell) {
    return ((cell.x & 1) == (cell.y & 1)) && ((cell.y & 1) == (cell.z & 1));
}

uint atlas_index_for_cell(ivec3 cell) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    uint ind = indirection.data[idx_brick(brick)];
    if (ind == 0u) {
        // Sentinel for "no brick". Note: atlas index 0 is a valid cell, so we can't use 0 here.
        return 0xFFFFFFFFu;
    }
    uint brick_index = ind - 1u;
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

ivec3 snap_to_bcc(vec3 x) {
    // Nearest even-even-even or odd-odd-odd lattice point.
    ivec3 even = ivec3(round(x * 0.5)) * 2;
    ivec3 odd = ivec3(round((x - vec3(1.0)) * 0.5)) * 2 + ivec3(1, 1, 1);
    float de = length(x - vec3(even));
    float d_odd = length(x - vec3(odd));
    ivec3 c = (d_odd < de) ? odd : even;
    c = clamp(c, ivec3(0), ivec3(int(u.grid_info.x) - 1, int(u.grid_info.y) - 1, int(u.grid_info.z) - 1));
    if (bcc_parity(c)) {
        return c;
    }
    // Fallback: force parity by nudging towards bounds.
    ivec3 c2 = c;
    c2.x = clamp(c2.x + 1, 0, int(u.grid_info.x) - 1);
    if (bcc_parity(c2)) return c2;
    c2 = c;
    c2.y = clamp(c2.y + 1, 0, int(u.grid_info.y) - 1);
    if (bcc_parity(c2)) return c2;
    c2 = c;
    c2.z = clamp(c2.z + 1, 0, int(u.grid_info.z) - 1);
    if (bcc_parity(c2)) return c2;
    return c;
}

bool finite3(vec3 v) {
    bvec3 n = isnan(v);
    bvec3 f = isinf(v);
    return !any(n) && !any(f);
}

int slot_base(uint mat_id) {
    uint s = mat_id;
    if (s >= uint(MAT_SLOTS)) {
        s = uint(MAT_SLOTS - 1);
    }
    return IDX_BASE + int(s) * SLOT_STRIDE;
}

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }

    if (p == 0u) {
        stats_out.data[IDX_PARTICLE_COUNT] = int(count);
    }

    uint mat_id = meta.data[p].x;
    if (mat_id == 0u) {
        atomicAdd(stats_out.data[IDX_INACTIVE_COUNT], 1);
        return;
    }

    vec3 x = pos_mass.data[p].xyz;
    float m = pos_mass.data[p].w;
    vec3 v = vel_vol.data[p].xyz;

    if (!finite3(x) || !finite3(v) || isnan(m) || isinf(m)) {
        atomicAdd(stats_out.data[IDX_NAN_COUNT], 1);
        return;
    }

    atomicAdd(stats_out.data[IDX_ACTIVE_COUNT], 1);

    int base = slot_base(mat_id);

    atomicAdd(stats_out.data[base + 0], 1);
    int m_fixed = int(clamp(m * MASS_FP, 0.0, 2.0e9));
    atomicAdd(stats_out.data[base + 1], m_fixed);

    float speed = length(v);
    int sp_sum = int(clamp(speed * SPEED_SUM_FP, 0.0, 2.0e9));
    atomicAdd(stats_out.data[base + 2], sp_sum);
    int sp_max = int(clamp(speed * SPEED_MAX_FP, 0.0, 2.0e9));
    atomicMax(stats_out.data[base + 3], sp_max);

    // Overlap with static solids (particle snapped into an occupied static TO cell).
    ivec3 cell = snap_to_bcc(x);
    if (in_bounds(cell) && bcc_parity(cell)) {
        uint ai = atlas_index_for_cell(cell);
        if (ai != 0xFFFFFFFFu && static_atlas.data[ai] != 0u) {
            atomicAdd(stats_out.data[base + 4], 1);
        }
    }

    // Bounding box.
    ivec3 xs = ivec3(
        int(clamp(x.x * POS_FP, -2.0e9, 2.0e9)),
        int(clamp(x.y * POS_FP, -2.0e9, 2.0e9)),
        int(clamp(x.z * POS_FP, -2.0e9, 2.0e9))
    );
    atomicMin(stats_out.data[base + 5], xs.x);
    atomicMin(stats_out.data[base + 6], xs.y);
    atomicMin(stats_out.data[base + 7], xs.z);
    atomicMax(stats_out.data[base + 8], xs.x);
    atomicMax(stats_out.data[base + 9], xs.y);
    atomicMax(stats_out.data[base + 10], xs.z);

    // Center-of-mass accumulators (scaled).
    int mx = int(clamp((m * x.x) * MPOS_FP, -2.0e9, 2.0e9));
    int my = int(clamp((m * x.y) * MPOS_FP, -2.0e9, 2.0e9));
    int mz = int(clamp((m * x.z) * MPOS_FP, -2.0e9, 2.0e9));
    atomicAdd(stats_out.data[base + 11], mx);
    atomicAdd(stats_out.data[base + 12], my);
    atomicAdd(stats_out.data[base + 13], mz);
}
