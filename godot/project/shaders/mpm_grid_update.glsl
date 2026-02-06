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

bool in_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < int(u.grid_info.x)
        && p.y < int(u.grid_info.y)
        && p.z < int(u.grid_info.z);
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

uint atlas_index_for_cell_direct(ivec3 cell) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    if (brick.x < 0 || brick.y < 0 || brick.z < 0
        || brick.x >= int(u.brick_info.x)
        || brick.y >= int(u.brick_info.y)
        || brick.z >= int(u.brick_info.z)) {
        return 0xffffffffu;
    }
    uint brick_index = uint(brick.x)
        + uint(brick.y) * uint(u.brick_info.x)
        + uint(brick.z) * uint(u.brick_info.x) * uint(u.brick_info.y);
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
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
    bool is_static_node = static_atlas.data[idx] != 0u;
    if (is_static_node) {
        v = vec3(0.0);
    } else {
        // Boundary condition: prevent grid velocity from flowing into neighboring static voxels.
        // This reduces tunneling and "pressure leaks" compared to only testing particles.
        ivec3 neigh[14] = ivec3[14](
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
        for (int i = 0; i < 14; i++) {
            ivec3 nc = cell + neigh[i];
            if (!in_bounds(nc) || !bcc_parity(nc)) {
                continue;
            }
            uint ni = atlas_index_for_cell_direct(nc);
            if (ni == 0xffffffffu) {
                continue;
            }
            if (static_atlas.data[ni] == 0u) {
                continue;
            }
            vec3 fn = normalize(vec3(neigh[i]));
            float toward = dot(v, fn);
            if (toward > 0.0) {
                v -= toward * fn;
            }
        }
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
