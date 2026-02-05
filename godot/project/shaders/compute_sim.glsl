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
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
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

layout(set = 0, binding = 4, std430) readonly buffer ActiveList {
    uint data[];
} active_list;
layout(set = 0, binding = 5, std430) readonly buffer SeedIn {
    uint data[];
} seed_in;
layout(set = 0, binding = 6, std430) buffer SeedOut {
    uint data[];
} seed_out;
layout(set = 0, binding = 7, std430) readonly buffer MaterialProps {
    vec4 data[];
} material_props;

const uint GLASS_MATERIAL = 8u;
const uint INVISIBLE_MATERIAL = 9u;
const uint WATER_MATERIAL = 2u;

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

uint hash_cell(ivec3 c, uint seed) {
    return uint(c.x * 73856093 ^ c.y * 19349663 ^ c.z * 83492791) ^ seed;
}

ivec3 brick_from_index(uint brick_index) {
    uint bx = brick_index % uint(u.brick_info.x);
    uint by = (brick_index / uint(u.brick_info.x)) % uint(u.brick_info.y);
    uint bz = brick_index / (uint(u.brick_info.x) * uint(u.brick_info.y));
    return ivec3(int(bx), int(by), int(bz));
}

void main() {
    const uint LOCAL_SIZE = 4u;
    uint brick_size = uint(u.brick_info.w);
    uint groups_per_brick = (brick_size + LOCAL_SIZE - 1u) / LOCAL_SIZE;
    if (groups_per_brick == 0u) {
        return;
    }
    uint brick_list_index = gl_WorkGroupID.x / groups_per_brick;
    uint tile_x = gl_WorkGroupID.x - brick_list_index * groups_per_brick;
    uint tile_y = gl_WorkGroupID.y;
    uint tile_z = gl_WorkGroupID.z;
    if (tile_y >= groups_per_brick || tile_z >= groups_per_brick) {
        return;
    }
    uint brick_index = active_list.data[brick_list_index];
    ivec3 brick = brick_from_index(brick_index);
    uvec3 local_id = gl_LocalInvocationID.xyz;
    uint lx = tile_x * LOCAL_SIZE + local_id.x;
    uint ly = tile_y * LOCAL_SIZE + local_id.y;
    uint lz = tile_z * LOCAL_SIZE + local_id.z;
    if (lx >= brick_size || ly >= brick_size || lz >= brick_size) {
        return;
    }
    ivec3 cell = brick * int(brick_size) + ivec3(int(lx), int(ly), int(lz));
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
    bool is_water = material == WATER_MATERIAL;
    uint seed = seed_in.data[self_idx];
    if (material == GLASS_MATERIAL || material == INVISIBLE_MATERIAL) {
        if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
            seed_out.data[self_idx] = 0u;
        }
        return;
    }

    vec3 gravity = u.debug_info.xyz;
    if (length(gravity) < 1e-3) {
        gravity = vec3(0.0, -1.0, 0.0);
    }
    gravity = normalize(gravity);

    uint mat_index = material * 2u;
    vec4 props0 = material_props.data[mat_index + 0u];
    vec4 props1 = material_props.data[mat_index + 1u];
    float friction = props0.y;
    float viscosity = props0.z;
    float cohesion = props0.w;
    float drag = props1.x;
    float rest_cost = props1.y;
    float lateral_cost = props1.z;
    float gravity_bias = props1.w;

    const int NEIGHBOR_COUNT = 14;
    ivec3 offsets[NEIGHBOR_COUNT] = ivec3[NEIGHBOR_COUNT](
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
    float stay_cost = rest_cost + drag;
    float best_cost = stay_cost;
    ivec3 best_offset = ivec3(0);
    bool can_move = false;
    for (int i = 0; i < NEIGHBOR_COUNT; i++) {
        ivec3 offset = offsets[i];
        float down = dot(vec3(offset), gravity);
        if (is_water) {
            if (down < 0.0) {
                continue;
            }
        } else {
            if (down <= 0.0) {
                continue;
            }
        }
        ivec3 target = cell + offset;
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
        float move_len = length(vec3(offset));
        float cost = friction + viscosity + cohesion + drag * move_len;
        if (down > 0.0) {
            cost -= down * gravity_bias;
        } else {
            cost += lateral_cost;
        }
        if (cost + 1e-4 < best_cost) {
            best_cost = cost;
            best_offset = offset;
            can_move = true;
        }
    }

    if (can_move && best_cost < stay_cost) {
        ivec3 target = cell + best_offset;
        uint t_idx = atlas_index_for_cell(target);
        if (t_idx != 0u && atomicCompSwap(atlas_out.data[t_idx], 0u, material) == 0u) {
            seed_out.data[t_idx] = seed;
            return;
        }
    }
    if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
        seed_out.data[self_idx] = seed;
    }
}
