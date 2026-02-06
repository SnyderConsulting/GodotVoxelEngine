#version 450

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

layout(set = 0, binding = 5, std430) buffer AtlasOut {
    uint data[];
} atlas_out;

// Per-cell particle position in grid coordinates; w>0 indicates a valid dynamic particle.
layout(set = 0, binding = 6, std430) buffer CellPos {
    vec4 data[];
} cell_pos;

const uint GLASS_MATERIAL = 8u;
const uint INVISIBLE_MATERIAL = 9u;

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

bool is_solid(uint mat_id) {
    return mat_id == GLASS_MATERIAL || mat_id == INVISIBLE_MATERIAL;
}

bool try_claim_cell(ivec3 cell, uint mat_id, vec3 render_pos) {
    if (!in_bounds(cell) || !bcc_parity(cell)) {
        return false;
    }
    uint ci = atlas_index_for_cell(cell);
    if (ci == 0u) {
        return false;
    }
    uint prev = atomicCompSwap(atlas_out.data[ci], 0u, mat_id);
    if (prev == 0u) {
        // Render center in grid-space coordinates. Ideally this is the particle's continuous position.
        // When we "spill" into neighboring cells due to contention, use the claimed cell center to
        // keep the raymarch cell lookup roughly aligned.
        cell_pos.data[ci] = vec4(render_pos, 1.0);
        return true;
    }
    return false;
}

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }

    uint mat_id = meta.data[p].x;
    if (mat_id == 0u) {
        return;
    }

    vec3 x = pos_mass.data[p].xyz;
    ivec3 base = snap_to_bcc(x);

    // Face-neighbor offsets in the BCC truncated-octahedron (Kelvin cell) topology.
    ivec3 neigh[14] = ivec3[14](
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

    // First try the nearest BCC cell.
    if (try_claim_cell(base, mat_id, x)) {
        return;
    }

    // Then try 1-hop neighbors (order randomized per particle to reduce contention).
    uint h = p * 1664525u + 1013904223u;
    int start = int(h % 14u);
    for (int k = 0; k < 14; k++) {
        int i = (start + k) % 14;
        ivec3 c = base + neigh[i];
        if (try_claim_cell(c, mat_id, vec3(c))) {
            return;
        }
    }

    // Dense piles can still fail the local neighborhood search (many particles share the same cells).
    // As a last resort, do a bounded random-walk search that explores further out without
    // stepping into static solids. This is render-only and aims to preserve the perception of
    // conserved mass even when the underlying continuum particles compress.
    const int WALK_LEN = 5;
    const int WALK_TRIES = 96;
    uint walk_seed = h ^ 0x9E3779B9u;
    for (int t = 0; t < WALK_TRIES; t++) {
        ivec3 c = base;
        bool ok = true;
        uint ws = walk_seed + uint(t) * 747796405u;
        for (int s = 0; s < WALK_LEN; s++) {
            ws = ws * 1664525u + 1013904223u;
            int ii = int(ws % 14u);
            c += neigh[ii];
            if (!in_bounds(c) || !bcc_parity(c)) {
                ok = false;
                break;
            }
            uint ci = atlas_index_for_cell(c);
            if (ci == 0u) {
                ok = false;
                break;
            }
            uint cm = atlas_out.data[ci];
            if (is_solid(cm)) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            continue;
        }
        if (try_claim_cell(c, mat_id, vec3(c))) {
            return;
        }
    }
}
