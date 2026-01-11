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
layout(set = 0, binding = 1, std430) readonly buffer ActiveCount {
    uint data[];
} active_count;
layout(set = 0, binding = 2, std430) buffer DispatchArgs {
    uint data[];
} dispatch_args;

void main() {
    const uint LOCAL_SIZE = 4u;
    uint brick_size = uint(u.brick_info.w);
    if (brick_size == 0u) {
        brick_size = 1u;
    }
    uint groups_per_brick = (brick_size + LOCAL_SIZE - 1u) / LOCAL_SIZE;
    if (groups_per_brick == 0u) {
        groups_per_brick = 1u;
    }
    uint count = active_count.data[0];
    dispatch_args.data[0] = count * groups_per_brick;
    dispatch_args.data[1] = groups_per_brick;
    dispatch_args.data[2] = groups_per_brick;
    dispatch_args.data[3] = 0u;
}
