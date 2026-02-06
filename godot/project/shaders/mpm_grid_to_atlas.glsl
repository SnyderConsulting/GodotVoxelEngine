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

layout(set = 0, binding = 2, std430) readonly buffer GridVel {
    vec4 data[];
} grid_vel;

layout(set = 0, binding = 3, std430) buffer AtlasOut {
    uint data[];
} atlas_out;

bool bcc_parity(ivec3 cell) {
    return ((cell.x & 1) == (cell.y & 1)) && ((cell.y & 1) == (cell.z & 1));
}

ivec3 brick_from_index(uint brick_index) {
    uint bx = brick_index % uint(u.brick_info.x);
    uint by = (brick_index / uint(u.brick_info.x)) % uint(u.brick_info.y);
    uint bz = brick_index / (uint(u.brick_info.x) * uint(u.brick_info.y));
    return ivec3(int(bx), int(by), int(bz));
}

ivec3 cell_from_atlas_index(uint atlas_index) {
    uint brick_size = uint(u.brick_info.w);
    uint cells_per_brick = brick_size * brick_size * brick_size;
    uint brick_index = atlas_index / cells_per_brick;
    uint local_index = atlas_index - brick_index * cells_per_brick;
    uint lx = local_index % brick_size;
    uint ly = (local_index / brick_size) % brick_size;
    uint lz = local_index / (brick_size * brick_size);
    ivec3 brick = brick_from_index(brick_index);
    return brick * int(brick_size) + ivec3(int(lx), int(ly), int(lz));
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    uint brick_grid = uint(u.brick_info.x) * uint(u.brick_info.y) * uint(u.brick_info.z);
    uint brick_size = uint(u.brick_info.w);
    uint total = brick_grid * brick_size * brick_size * brick_size;
    if (idx >= total) {
        return;
    }

    if (static_atlas.data[idx] != 0u) {
        return;
    }

    ivec3 cell = cell_from_atlas_index(idx);
    if (!bcc_parity(cell)) {
        return;
    }

    // grid_vel.w stores mass (float) after grid_update.
    float m = grid_vel.data[idx].w;
    const float MASS_THRESHOLD = 0.25;
    if (m > MASS_THRESHOLD) {
        // sand (material 1). static voxels already occupy atlas_out.
        atomicCompSwap(atlas_out.data[idx], 0u, 1u);
    }
}

