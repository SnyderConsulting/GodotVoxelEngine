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

layout(set = 0, binding = 2, std430) readonly buffer GridAccum {
    ivec4 data[];
} grid_accum;

layout(set = 0, binding = 3, std430) buffer GridVel {
    vec4 data[];
} grid_vel;

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

    ivec3 cell = cell_from_atlas_index(idx);
    if (!bcc_parity(cell)) {
        grid_vel.data[idx] = vec4(0.0);
        return;
    }

    ivec4 acc = grid_accum.data[idx];
    int m = acc.x;
    if (m <= 0) {
        grid_vel.data[idx] = vec4(0.0);
        return;
    }
    // Avoid massive velocities from dividing by tiny mass on sparse nodes.
    // (mass is fixed-point scaled by 10000 in p2g).
    const int MIN_MASS_FIXED = 50; // 0.005
    if (m < MIN_MASS_FIXED) {
        grid_vel.data[idx] = vec4(0.0);
        return;
    }

    vec3 v = vec3(acc.y, acc.z, acc.w) / float(m);

    float dt = max(0.0, u.grid_info.w);
    vec3 gdir = u.debug_info.xyz;
    float gmag = u.debug_info.w;
    if (length(gdir) < 1e-3) {
        gdir = vec3(0.0, -1.0, 0.0);
    }
    gdir = normalize(gdir);
    v += gdir * gmag * dt;

    // Static solid nodes: zero velocity.
    if (static_atlas.data[idx] != 0u) {
        v = vec3(0.0);
    }

    // World bounds collision (axis-aligned grid AABB).
    int gx = int(u.grid_info.x);
    int gy = int(u.grid_info.y);
    int gz = int(u.grid_info.z);
    if (cell.x <= 1 && v.x < 0.0) v.x = 0.0;
    if (cell.x >= gx - 2 && v.x > 0.0) v.x = 0.0;
    if (cell.y <= 1 && v.y < 0.0) v.y = 0.0;
    if (cell.y >= gy - 2 && v.y > 0.0) v.y = 0.0;
    if (cell.z <= 1 && v.z < 0.0) v.z = 0.0;
    if (cell.z >= gz - 2 && v.z > 0.0) v.z = 0.0;

    // Mild damping for stability.
    v *= 0.999;

    // Hard clamp for safety. Prevents single-particle blow-ups from destabilizing the whole grid.
    float vmax = 120.0;
    float vm = length(v);
    if (vm > vmax) {
        v *= vmax / vm;
    }

    grid_vel.data[idx] = vec4(v, float(m) / 10000.0);
}
