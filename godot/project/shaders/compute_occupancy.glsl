#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

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

layout(set = 0, binding = 2, std430) readonly buffer Atlas {
    uint data[];
} atlas;

layout(set = 0, binding = 3, std430) writeonly buffer Occupancy {
    uint data[];
} occ;

layout(set = 0, binding = 4, std430) buffer Metrics {
    uint data[];
} metrics;

uint idx_brick(ivec3 b) {
    return uint(b.x) + uint(b.y) * uint(u.brick_info.x)
        + uint(b.z) * uint(u.brick_info.x) * uint(u.brick_info.y);
}

void main() {
    uint brick_index = gl_GlobalInvocationID.x;
    uint brick_count = uint(u.brick_info.x * u.brick_info.y * u.brick_info.z);
    if (brick_index >= brick_count) {
        return;
    }
    uint ind = indirection.data[brick_index];
    if (ind == 0u) {
        occ.data[brick_index] = 0u;
        return;
    }
    uint brick_size = uint(u.brick_info.w);
    uint atlas_offset = (ind - 1u) * brick_size * brick_size * brick_size;
    uint count = brick_size * brick_size * brick_size;
    uint any = 0u;
    for (uint i = 0u; i < count; i++) {
        if (atlas.data[atlas_offset + i] != 0u) {
            any = 1u;
            break;
        }
    }
    if (any != 0u) {
        occ.data[brick_index] = 1u;
        atomicAdd(metrics.data[3], 1u);
        // Mark neighboring bricks as active so agents can move into empty space.
        ivec3 b = ivec3(
            int(brick_index % uint(u.brick_info.x)),
            int((brick_index / uint(u.brick_info.x)) % uint(u.brick_info.y)),
            int(brick_index / (uint(u.brick_info.x) * uint(u.brick_info.y)))
        );
        for (int dz = -1; dz <= 1; dz++) {
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    if (dx == 0 && dy == 0 && dz == 0) {
                        continue;
                    }
                    ivec3 nb = b + ivec3(dx, dy, dz);
                    if (nb.x < 0 || nb.y < 0 || nb.z < 0
                        || nb.x >= int(u.brick_info.x)
                        || nb.y >= int(u.brick_info.y)
                        || nb.z >= int(u.brick_info.z)) {
                        continue;
                    }
                    uint n_index = idx_brick(nb);
                    occ.data[n_index] = 1u;
                }
            }
        }
    } else {
        occ.data[brick_index] = 0u;
    }
}
