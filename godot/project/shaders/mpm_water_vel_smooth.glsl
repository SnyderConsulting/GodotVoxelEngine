#version 450

// Approximate the smoothing benefit of BCC linear box splines by applying a
// 14-neighbor weighted average to the water grid velocity field.
//
// This is not a full box-spline p2g/g2p transfer replacement, but it reduces the
// tetrahedral "grid crossing" artifacts by producing a smoother, more isotropic
// guidance field for the subsequent pressure projection and discrete transport.

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
    vec4 debug_info;
    vec4 world_rot_x;
    vec4 world_rot_y;
    vec4 world_rot_z;
} u;

layout(set = 0, binding = 1, std430) readonly buffer StaticAtlas {
    uint data[];
} static_atlas;

layout(set = 0, binding = 2, std430) readonly buffer SandOcc {
    uint data[];
} sand_occ;

layout(set = 0, binding = 3, std430) readonly buffer GridVelWaterIn {
    vec4 data[];
} vel_in;

layout(set = 0, binding = 4, std430) buffer GridVelWaterOut {
    vec4 data[];
} vel_out;

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

const ivec3 NEIGH[14] = ivec3[14](
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

float w_neigh(int i) {
    // Favor closer diagonal neighbors slightly (d^2=3 vs axial d^2=4).
    return (i < 6) ? 0.8 : 1.0;
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
        vel_out.data[idx] = vec4(0.0);
        return;
    }
    if (static_atlas.data[idx] != 0u) {
        vel_out.data[idx] = vec4(0.0);
        return;
    }

    vec4 self = vel_in.data[idx];
    float m0 = self.w;
    if (!(m0 > 0.0)) {
        vel_out.data[idx] = vec4(0.0);
        return;
    }

    float blend = clamp(u.world_rot_z.w, 0.0, 1.0);
    vec3 v0 = self.xyz;
    vec3 sum = v0 * m0;
    float wsum = m0;

    for (int i = 0; i < 14; i++) {
        ivec3 nc = cell + NEIGH[i];
        if (!in_bounds(nc) || !bcc_parity(nc)) {
            continue;
        }
        uint ni = atlas_index_for_cell_direct(nc);
        if (ni == 0xffffffffu) {
            continue;
        }
        if (static_atlas.data[ni] != 0u) {
            continue;
        }
        if (sand_occ.data[ni] != 0u) {
            // Don't smooth through sand barriers (treat as solid wall for water).
            continue;
        }

        vec4 n = vel_in.data[ni];
        float mn = n.w;
        if (!(mn > 0.0)) {
            continue;
        }
        float w = w_neigh(i);
        sum += n.xyz * (mn * w);
        wsum += mn * w;
    }

    vec3 v_avg = sum / max(1e-6, wsum);
    vec3 v = mix(v0, v_avg, blend);
    vel_out.data[idx] = vec4(v, m0);
}

