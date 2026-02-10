#version 450

// Build a coarse "water occupancy" field from particle positions so sand (and other solids)
// can treat water as an impermeable phase at voxel scale.

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

layout(set = 0, binding = 2, std430) readonly buffer ParticlePosMass {
    vec4 data[];
} pos_mass;

layout(set = 0, binding = 3, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 4, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

// 1u if the cell is "occupied by water" this substep, else 0u.
layout(set = 0, binding = 5, std430) buffer WaterOccOut {
    uint data[];
} water_occ;

const uint WATER_MATERIAL = 2u;
const ivec3 OFFSETS[15] = ivec3[15](
    ivec3(0, 0, 0),
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
        return 0u;
    }
    uint brick_index = ind - 1u;
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

ivec3 snap_to_bcc(vec3 x) {
    ivec3 even = ivec3(round(x * 0.5)) * 2;
    ivec3 odd = ivec3(round((x - vec3(1.0)) * 0.5)) * 2 + ivec3(1, 1, 1);
    float de = length(x - vec3(even));
    float d_odd = length(x - vec3(odd));
    ivec3 c = (d_odd < de) ? odd : even;
    c = clamp(c, ivec3(0), ivec3(int(u.grid_info.x) - 1, int(u.grid_info.y) - 1, int(u.grid_info.z) - 1));
    if (bcc_parity(c)) {
        return c;
    }
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

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }

    uint mat_id = meta.data[p].x;
    if (mat_id != WATER_MATERIAL) {
        return;
    }

    vec3 x = pos_mass.data[p].xyz;
    ivec3 cell = snap_to_bcc(x);
    for (int i = 0; i < 15; i++) {
        ivec3 c = cell + OFFSETS[i];
        if (!in_bounds(c) || !bcc_parity(c)) {
            continue;
        }
        uint ai = atlas_index_for_cell(c);
        if (ai == 0u) {
            continue;
        }
        atomicOr(water_occ.data[ai], 1u);
    }
}

