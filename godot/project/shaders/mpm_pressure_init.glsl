#version 450

// Build divergence (RHS) for a BCC pressure projection and reset the pressure field.
// This targets the "water stacking" artifact in a single-occupancy voxel simulation by
// enforcing an approximately divergence-free velocity field for water voxels.

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

layout(set = 0, binding = 3, std430) readonly buffer CellClaim {
    uint data[];
} cell_claim;

layout(set = 0, binding = 4, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 5, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 6, std430) readonly buffer GridVelIn {
    vec4 data[];
} grid_vel;

layout(set = 0, binding = 7, std430) buffer DivergenceOut {
    float data[];
} divergence;

layout(set = 0, binding = 8, std430) buffer PressureOut {
    float data[];
} pressure;

const uint WATER_MATERIAL = 2u;

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

// 14-neighbor BCC stencil used throughout the project (6 axial at distance 2 + 8 diagonal at distance sqrt(3)).
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

float inv_d2_for_neigh(int i) {
    // Axial neighbors are 2 units away => d^2 = 4. Diagonals are sqrt(3) away => d^2 = 3.
    return (i < 6) ? 0.25 : (1.0 / 3.0);
}

bool is_water_cell(uint atlas_idx) {
    uint cid = cell_claim.data[atlas_idx];
    if (cid == 0u) {
        return false;
    }
    uint p = cid - 1u;
    uint count = particle_count.data[0];
    if (p >= count) {
        return false;
    }
    return meta.data[p].x == WATER_MATERIAL;
}

bool is_solid_cell(uint atlas_idx, bool water_here) {
    if (static_atlas.data[atlas_idx] != 0u) {
        return true;
    }
    // sand_occ is intentionally dilated for impermeability; don't let it "erase" water cells.
    if (!water_here && sand_occ.data[atlas_idx] != 0u) {
        return true;
    }
    return false;
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
        divergence.data[idx] = 0.0;
        pressure.data[idx] = 0.0;
        return;
    }

    bool water_here = is_water_cell(idx);
    if (!water_here || static_atlas.data[idx] != 0u) {
        divergence.data[idx] = 0.0;
        pressure.data[idx] = 0.0;
        return;
    }

    vec3 v = grid_vel.data[idx].xyz;
    float div = 0.0;
    for (int i = 0; i < 14; i++) {
        ivec3 nc = cell + NEIGH[i];
        if (!in_bounds(nc) || !bcc_parity(nc)) {
            continue;
        }
        uint ni = atlas_index_for_cell_direct(nc);
        if (ni == 0xffffffffu) {
            continue;
        }

        bool nwater = is_water_cell(ni);
        bool nsolid = is_solid_cell(ni, nwater);
        if (nsolid) {
            // Free-slip / no-flow boundary: do not include solid neighbors in divergence.
            continue;
        }

        vec3 vj = grid_vel.data[ni].xyz;
        vec3 o = vec3(NEIGH[i]);
        float invd2 = inv_d2_for_neigh(i);
        // 0.5 factor corrects for the symmetric +/- directions in the stencil (central difference).
        div += 0.5 * dot(vj - v, o) * invd2;
    }

    float dt = max(1e-6, u.grid_info.w);
    divergence.data[idx] = div / dt;
    pressure.data[idx] = 0.0;
}
