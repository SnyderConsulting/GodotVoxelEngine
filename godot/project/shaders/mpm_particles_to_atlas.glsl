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

// Persistent per-particle render mapping for stable voxelization across frames.
// xyz = last claimed render cell (grid coords), w = packed base cell (10 bits per axis) with a valid bit.
layout(set = 0, binding = 7, std430) buffer ParticleRenderCell {
    uvec4 data[];
} render_cell;

const uint GLASS_MATERIAL = 8u;
const uint INVISIBLE_MATERIAL = 9u;

const uint RENDER_CELL_VALID_BIT = 0x80000000u;
const uint RENDER_CELL_BASE_MASK = 0x3FFFFFFFu;

uint pack_cell_10bits(ivec3 c) {
    return uint(c.x) | (uint(c.y) << 10) | (uint(c.z) << 20);
}

ivec3 unpack_cell_10bits(uint p) {
    return ivec3(
        int(p & 1023u),
        int((p >> 10) & 1023u),
        int((p >> 20) & 1023u)
    );
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

bool try_claim_cell(ivec3 cell, uint mat_id, vec3 render_pos, uint p, ivec3 base) {
    if (!in_bounds(cell) || !bcc_parity(cell)) {
        return false;
    }
    uint ci = atlas_index_for_cell(cell);
    if (ci == 0u) {
        return false;
    }
    uint prev = atomicCompSwap(atlas_out.data[ci], 0u, mat_id);
    if (prev == 0u) {
        // Render center in grid-space coordinates.
        // For VoxLand's voxel UI, keep particles snapped to BCC lattice cells so voxels don't
        // appear to "partially fill" cells as the continuum particles advect.
        cell_pos.data[ci] = vec4(render_pos, 1.0);
        render_cell.data[p] = uvec4(uint(cell.x), uint(cell.y), uint(cell.z), pack_cell_10bits(base) | RENDER_CELL_VALID_BIT);
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
    if (try_claim_cell(base, mat_id, vec3(base), p, base)) {
        return;
    }

    // If the base cell is unavailable (static voxel or unexpected contention), prefer the previous
    // render cell as a stabilization step. This avoids "teleport" flicker, but only after the base
    // claim has already failed (so we don't violate discrete voxel conservation when base is free).
    uvec4 prev_rc = render_cell.data[p];
    if ((prev_rc.w & RENDER_CELL_VALID_BIT) != 0u) {
        ivec3 prev_cell = ivec3(prev_rc.xyz);
        vec3 dxp = x - vec3(prev_cell);
        float d2 = dot(dxp, dxp);
        if (d2 <= 1.0) {
            if (try_claim_cell(prev_cell, mat_id, vec3(prev_cell), p, base)) {
                return;
            }
        }
    }

    // Then try 1-hop neighbors (order randomized per particle to reduce contention).
    uint h = p * 1664525u + 1013904223u;
    int start = int(h % 14u);
    for (int k = 0; k < 14; k++) {
        int i = (start + k) % 14;
        ivec3 c = base + neigh[i];
        if (try_claim_cell(c, mat_id, vec3(c), p, base)) {
            return;
        }
    }

    // Dense piles can still fail the 1-hop neighborhood search (many particles share the same cells).
    // Prefer a wider *local* search over long random walks so voxels don't "teleport" far from the
    // underlying particles (which looks like sand being pushed to corners).
    uint h2 = h ^ 0x9E3779B9u;
    int start0 = int(h2 % 14u);
    int start1 = int((h2 >> 4) % 14u);
    // 2-hop Kelvin neighborhood (<= 4-ish cells away).
    for (int a = 0; a < 14; a++) {
        ivec3 c1 = base + neigh[(start0 + a) % 14];
        for (int b = 0; b < 14; b++) {
            ivec3 c = c1 + neigh[(start1 + b) % 14];
            if (try_claim_cell(c, mat_id, vec3(c), p, base)) {
                return;
            }
        }
    }

    // Final fallback: bounded randomized samples in a small cube around base.
    const int RAND_TRIES = 64;
    const int R = 6;
    const int RY = 2;
    uint s = h2 ^ 0xA341316Cu;
    for (int t = 0; t < RAND_TRIES; t++) {
        s = s * 1664525u + 1013904223u;
        int ox = int(s % uint(2 * R + 1)) - R;
        s = s * 1664525u + 1013904223u;
        int oy = int(s % uint(2 * RY + 1)) - RY;
        s = s * 1664525u + 1013904223u;
        int oz = int(s % uint(2 * R + 1)) - R;

        // Force parity: offsets must be all-even or all-odd so base+offset stays on the BCC lattice.
        if ((s & 1u) != 0u) {
            if ((ox & 1) == 0) ox += (ox >= 0) ? 1 : -1;
            if ((oy & 1) == 0) oy += (oy >= 0) ? 1 : -1;
            if ((oz & 1) == 0) oz += (oz >= 0) ? 1 : -1;
        } else {
            ox &= ~1;
            oy &= ~1;
            oz &= ~1;
        }

        ivec3 c = base + ivec3(ox, oy, oz);
        if (try_claim_cell(c, mat_id, vec3(c), p, base)) {
            return;
        }
    }
}
