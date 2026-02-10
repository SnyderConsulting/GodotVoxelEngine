#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

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

layout(set = 0, binding = 1, std430) readonly buffer Indirection {
    uint data[];
} indirection;

layout(set = 0, binding = 2, std430) readonly buffer ParticlePosMass {
    vec4 data[];
} pos_mass;

layout(set = 0, binding = 3, std430) readonly buffer ParticleF {
    mat3 data[];
} f_in;

layout(set = 0, binding = 4, std430) buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 5, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 6, std430) readonly buffer RigidMap {
    uint data[];
} rigid_map;

const uint STONE_MATERIAL = 4u;
const uint FLAG_BONDS_INIT = 1u << 0;

uint idx_brick(ivec3 b) {
    return uint(b.x) + uint(b.y) * uint(u.brick_info.x)
        + uint(b.z) * uint(u.brick_info.x) * uint(u.brick_info.y);
}

bool in_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < int(u.grid_info.x)
        && p.y < int(u.grid_info.y)
        && p.z < int(u.grid_info.z);
}

bool bcc_parity(ivec3 cell) {
    return ((cell.x & 1) == (cell.y & 1)) && ((cell.y & 1) == (cell.z & 1));
}

uint atlas_index_for_cell(ivec3 cell) {
    int brick_size = int(u.brick_info.w);
    ivec3 brick = cell / brick_size;
    uint ind = indirection.data[idx_brick(brick)];
    if (ind == 0u) {
        return 0u;
    }
    uint brick_index = ind - 1u;
    ivec3 local = cell - brick * brick_size;
    uint local_index = uint(local.x)
        + uint(local.y) * uint(brick_size)
        + uint(local.z) * uint(brick_size * brick_size);
    return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

ivec3 snap_to_bcc(vec3 x) {
    ivec3 even = ivec3(round(x * 0.5)) * 2;
    ivec3 odd = ivec3(round((x - vec3(1.0)) * 0.5)) * 2 + ivec3(1, 1, 1);
    float de = length(x - vec3(even));
    float d_odd = length(x - vec3(odd));
    ivec3 c = (d_odd < de) ? odd : even;
    c = clamp(c, ivec3(0), ivec3(int(u.grid_info.x) - 1, int(u.grid_info.y) - 1, int(u.grid_info.z) - 1));
    return c;
}

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }
    if (meta.data[p].x != STONE_MATERIAL) {
        return;
    }

    vec3 x = pos_mass.data[p].xyz;
    ivec3 cell = snap_to_bcc(x);
    if (!in_bounds(cell) || !bcc_parity(cell)) {
        return;
    }

    // Build bonds from neighborhood occupancy.
    ivec3 diag_offsets[8] = ivec3[8](
        ivec3(-1, -1, -1),
        ivec3(-1, -1,  1),
        ivec3(-1,  1, -1),
        ivec3(-1,  1,  1),
        ivec3( 1, -1, -1),
        ivec3( 1, -1,  1),
        ivec3( 1,  1, -1),
        ivec3( 1,  1,  1)
    );
    ivec3 axis_offsets[6] = ivec3[6](
        ivec3( 2,  0,  0),
        ivec3(-2,  0,  0),
        ivec3( 0,  2,  0),
        ivec3( 0, -2,  0),
        ivec3( 0,  0,  2),
        ivec3( 0,  0, -2)
    );

    uint occ_mask = 0u;
    for (int i = 0; i < 8; i++) {
        ivec3 n = cell + diag_offsets[i];
        if (!in_bounds(n) || !bcc_parity(n)) {
            continue;
        }
        uint ni = atlas_index_for_cell(n);
        if (ni == 0u) {
            continue;
        }
        if (rigid_map.data[ni] != 0u) {
            occ_mask |= (1u << uint(i));
        }
    }
    for (int i = 0; i < 6; i++) {
        ivec3 n = cell + axis_offsets[i];
        if (!in_bounds(n) || !bcc_parity(n)) {
            continue;
        }
        uint ni = atlas_index_for_cell(n);
        if (ni == 0u) {
            continue;
        }
        if (rigid_map.data[ni] != 0u) {
            occ_mask |= (1u << uint(8 + i));
        }
    }

    // Implementation note: fracture_enabled is passed via an otherwise-unused UBO slot.
    // We encode it as u.world_rot_x.w to avoid changing the shared Params layout.
    bool do_fracture = (u.world_rot_x.w > 0.5);

    // Persist bonds across frames for fracture, but allow healing when fracture is disabled.
    uint flags = meta.data[p].y;
    uint mask = 0u;
    if (!do_fracture) {
        mask = occ_mask;
        flags |= FLAG_BONDS_INIT;
    } else {
        if ((flags & FLAG_BONDS_INIT) == 0u) {
            mask = occ_mask;
            flags |= FLAG_BONDS_INIT;
        } else {
            mask = meta.data[p].z & occ_mask;
        }
    }

    if (do_fracture) {
        // Fracture: break bonds under tensile stress along each face normal.
        mat3 F = f_in.data[p];
        float J = determinant(F);
        if (!(J > 0.0) || abs(J) < 1e-6) {
            F = mat3(1.0);
            J = 1.0;
        }
        // Neo-Hookean Cauchy stress.
        const float mu = 55.0;
        const float lambda = 95.0;
        mat3 FinvT = transpose(inverse(F));
        float logJ = log(max(J, 1e-6));
        mat3 P = mu * (F - FinvT) + lambda * logJ * FinvT;
        mat3 sigma = (P * transpose(F)) / max(J, 1e-6);

        // Higher threshold reduces "popcorn" fracture and improves stability of small islands.
        const float TENSILE = 180.0;
        for (int i = 0; i < 8; i++) {
            if ((mask & (1u << uint(i))) == 0u) {
                continue;
            }
            vec3 n = normalize(vec3(diag_offsets[i]));
            float s = dot(n, sigma * n);
            if (s > TENSILE) {
                mask &= ~(1u << uint(i));
            }
        }
        for (int i = 0; i < 6; i++) {
            uint bit = 1u << uint(8 + i);
            if ((mask & bit) == 0u) {
                continue;
            }
            vec3 n = normalize(vec3(axis_offsets[i]));
            float s = dot(n, sigma * n);
            if (s > TENSILE) {
                mask &= ~bit;
            }
        }
    }

    meta.data[p].y = flags;
    meta.data[p].z = mask;
}
