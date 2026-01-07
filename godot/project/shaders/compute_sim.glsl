#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std140) uniform Params {
    vec4 grid_info;   // xyz = grid size
    vec4 origin;
    vec4 cam_pos;
    vec4 cam_right;
    vec4 cam_up;
    vec4 cam_forward;
    vec4 screen;
    vec4 misc;
    vec4 brick_info;  // xyz = brick grid dims, w = brick size
    vec4 debug_info;
} u;

layout(set = 0, binding = 1, std430) readonly buffer Indirection {
    uint data[];
} indirection;

layout(set = 0, binding = 2, std430) readonly buffer AtlasIn {
    uint data[];
} atlas_in;

layout(set = 0, binding = 3, std430) buffer AtlasOut {
    uint data[];
} atlas_out;

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

uint hash_cell(ivec3 c) {
    return uint(c.x * 73856093 ^ c.y * 19349663 ^ c.z * 83492791);
}

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (!in_bounds(cell)) {
        return;
    }
    if (!bcc_parity(cell)) {
        return;
    }
    uint self_idx = atlas_index_for_cell(cell);
    if (self_idx == 0u) {
        return;
    }
    uint material = atlas_in.data[self_idx];
    if (material == 0u) {
        return;
    }

    ivec3 down = ivec3(0, -2, 0);
    ivec3 diag[4] = ivec3[4](
        ivec3(1, -1, 1),
        ivec3(1, -1, -1),
        ivec3(-1, -1, 1),
        ivec3(-1, -1, -1)
    );

    ivec3 candidates[5];
    candidates[0] = down;
    uint h = hash_cell(cell);
    uint base = h & 3u;
    for (int i = 0; i < 4; i++) {
        candidates[i + 1] = diag[int((base + uint(i)) & 3u)];
    }

    bool moved = false;
    for (int i = 0; i < 5; i++) {
        ivec3 target = cell + candidates[i];
        if (!in_bounds(target)) {
            continue;
        }
        if (!bcc_parity(target)) {
            continue;
        }
        uint t_idx = atlas_index_for_cell(target);
        if (t_idx == 0u) {
            continue;
        }
        if (atlas_in.data[t_idx] != 0u) {
            continue;
        }
        if (atomicCompSwap(atlas_out.data[t_idx], 0u, material) == 0u) {
            moved = true;
            break;
        }
    }

    if (!moved) {
        atomicCompSwap(atlas_out.data[self_idx], 0u, material);
    }
}
