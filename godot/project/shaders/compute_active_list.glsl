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
} u;
layout(set = 0, binding = 1, std430) readonly buffer Occupancy {
    uint data[];
} occ;
layout(set = 0, binding = 2, std430) writeonly buffer ActiveList {
    uint data[];
} active_list;
layout(set = 0, binding = 3, std430) buffer ActiveCount {
    uint data[];
} active_count;

void main() {
    uint brick_index = gl_GlobalInvocationID.x;
    uint brick_count = uint(u.brick_info.x * u.brick_info.y * u.brick_info.z);
    if (brick_index >= brick_count) {
        return;
    }
    if (occ.data[brick_index] == 0u) {
        return;
    }
    uint write_index = atomicAdd(active_count.data[0], 1u);
    active_list.data[write_index] = brick_index;
}
