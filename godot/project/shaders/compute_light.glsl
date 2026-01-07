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

layout(set = 0, binding = 2, std430) readonly buffer Atlas {
    uint data[];
} atlas;

layout(set = 0, binding = 3, std430) readonly buffer LightIn {
    uint data[];
} light_in;

layout(set = 0, binding = 4, std430) buffer LightOut {
    uint data[];
} light_out;

const uint LIGHT_MAX = 15u;

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

uint atlas_index_for_cell(ivec3 cell, out bool valid) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    uint ind = indirection.data[idx_brick(brick)];
    if (ind == 0u) {
        valid = false;
        return 0u;
    }
    valid = true;
    uint brick_index = ind - 1u;
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

void main() {
    ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
    if (!in_bounds(cell)) {
        return;
    }
    if (!bcc_parity(cell)) {
        return;
    }
    bool valid = false;
    uint idx = atlas_index_for_cell(cell, valid);
    if (!valid) {
        return;
    }

    uint mat = atlas.data[idx];
    bool solid = mat != 0u;
    uint emit = 0u;
    if (!solid && cell.y == int(u.grid_info.y) - 1) {
        emit = LIGHT_MAX;
    }

    uint out_light = 0u;
    if (!solid) {
        uint max_neighbor = 0u;
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
            if (!bcc_parity(neighbor)) {
                continue;
            }
            bool n_valid = false;
            uint n_idx = atlas_index_for_cell(neighbor, n_valid);
            if (!n_valid) {
                continue;
            }
            if (atlas.data[n_idx] != 0u) {
                continue;
            }
            uint n_light = light_in.data[n_idx];
            if (n_light > max_neighbor) {
                max_neighbor = n_light;
            }
        }
        if (max_neighbor > 0u) {
            out_light = max_neighbor - 1u;
        }
        if (emit > out_light) {
            out_light = emit;
        }
    }

    light_out.data[idx] = out_light;
}
