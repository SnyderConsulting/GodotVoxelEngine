#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

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
    vec4 debug_info;  // xyz = gravity dir (grid space), w = gravity strength
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
} u;

layout(set = 0, binding = 1, std430) readonly buffer StaticAtlas {
    uint data[];
} static_atlas;

layout(set = 0, binding = 2, std430) buffer AtlasOut {
    uint data[];
} atlas_out;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    uint brick_grid = uint(u.brick_info.x) * uint(u.brick_info.y) * uint(u.brick_info.z);
    uint brick_size = uint(u.brick_info.w);
    uint total = brick_grid * brick_size * brick_size * brick_size;
    if (idx >= total) {
        return;
    }
    atlas_out.data[idx] = static_atlas.data[idx];
}

