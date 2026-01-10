#[compute]
#version 450
#VERSION_DEFINES

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
    occ.data[brick_index] = any;
    if (any != 0u) {
        atomicAdd(metrics.data[3], 1u);
    }
}
