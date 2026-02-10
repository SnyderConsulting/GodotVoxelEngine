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
    vec4 debug_info;  // xyz = gravity dir (grid space), w = gravity strength
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

layout(set = 0, binding = 3, std430) readonly buffer ParticleVelVol {
    vec4 data[];
} vel_vol;

layout(set = 0, binding = 4, std430) readonly buffer ParticleC {
    mat3 data[];
} c_in;

layout(set = 0, binding = 5, std430) readonly buffer ParticleF {
    mat3 data[];
} f_in;

layout(set = 0, binding = 6, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 7, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

// Grid accumulation per cell index (aligned with atlas index):
// x = mass_fixed, yzw = momentum_fixed (scaled)
layout(set = 0, binding = 8, std430) buffer GridAccum {
    ivec4 data[];
} grid_accum;

const float FP_SCALE = 10000.0;

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

vec2 lame_for_material(uint material_id) {
    // Tuned for grid-space units and dt ~= 1/120..1/240 with substeps.
    // x = mu (shear), y = lambda (bulk).
    if (material_id == 1u) { // sand
        // Sand: moderate shear with a stiff bulk response so grains resist numerical compression
        // (helps keep one-particle-per-voxel behavior in the UI).
        return vec2(25.0, 110.0);
    }
    if (material_id == 2u) { // water (fluid-ish)
        // Fluid: no shear, but relatively stiff bulk to reduce compressibility artifacts.
        return vec2(0.0, 70.0);
    }
    if (material_id == 4u) { // stone (stiff elastic)
        return vec2(55.0, 95.0);
    }
    // default
    return vec2(10.0, 18.0);
}

ivec3 clamp_cube_min(ivec3 cube_min) {
    // Ensure the 2x2x2 cube stays within [0..grid-1].
    ivec3 max_min = ivec3(int(u.grid_info.x) - 3, int(u.grid_info.y) - 3, int(u.grid_info.z) - 3);
    return clamp(cube_min, ivec3(0), max_min);
}

void compute_tetra(
    vec3 x,
    out ivec3 v0,
    out ivec3 v1,
    out ivec3 v2,
    out ivec3 v3,
    out vec4 w,
    out vec3 gw0,
    out vec3 gw1,
    out vec3 gw2,
    out vec3 gw3
) {
    v0 = ivec3(0);
    v1 = ivec3(0);
    v2 = ivec3(0);
    v3 = ivec3(0);
    w = vec4(1.0, 0.0, 0.0, 0.0);
    gw0 = vec3(0.0);
    gw1 = vec3(0.0);
    gw2 = vec3(0.0);
    gw3 = vec3(0.0);

    ivec3 cube_min = ivec3(floor(x * 0.5)) * 2;
    cube_min = clamp_cube_min(cube_min);
    ivec3 center = cube_min + ivec3(1, 1, 1); // odd-parity BCC point

    vec3 r = x - vec3(center);
    vec3 ar = abs(r);

    int axis = 0;
    if (ar.y >= ar.x && ar.y >= ar.z) {
        axis = 1;
    } else if (ar.z >= ar.x && ar.z >= ar.y) {
        axis = 2;
    }
    float s = (axis == 0) ? r.x : ((axis == 1) ? r.y : r.z);
    int face_sign = (s >= 0.0) ? 1 : -1;

    vec3 f = x - vec3(cube_min); // in [0,2)
    float u2 = 0.0;
    float v2f = 0.0;
    if (axis == 0) { // x face, use yz for triangle split
        u2 = f.y;
        v2f = f.z;
    } else if (axis == 1) { // y face, use xz
        u2 = f.x;
        v2f = f.z;
    } else { // z face, use xy
        u2 = f.x;
        v2f = f.y;
    }
    bool low = (u2 + v2f) <= 2.0;

    v0 = center;
    if (axis == 0) {
        int fx = (face_sign > 0) ? 2 : 0;
        if (low) {
            v1 = cube_min + ivec3(fx, 0, 0);
            v2 = cube_min + ivec3(fx, 2, 0);
            v3 = cube_min + ivec3(fx, 0, 2);
        } else {
            v1 = cube_min + ivec3(fx, 2, 2);
            v2 = cube_min + ivec3(fx, 0, 2);
            v3 = cube_min + ivec3(fx, 2, 0);
        }
    } else if (axis == 1) {
        int fy = (face_sign > 0) ? 2 : 0;
        if (low) {
            v1 = cube_min + ivec3(0, fy, 0);
            v2 = cube_min + ivec3(2, fy, 0);
            v3 = cube_min + ivec3(0, fy, 2);
        } else {
            v1 = cube_min + ivec3(2, fy, 2);
            v2 = cube_min + ivec3(0, fy, 2);
            v3 = cube_min + ivec3(2, fy, 0);
        }
    } else {
        int fz = (face_sign > 0) ? 2 : 0;
        if (low) {
            v1 = cube_min + ivec3(0, 0, fz);
            v2 = cube_min + ivec3(2, 0, fz);
            v3 = cube_min + ivec3(0, 2, fz);
        } else {
            v1 = cube_min + ivec3(2, 2, fz);
            v2 = cube_min + ivec3(0, 2, fz);
            v3 = cube_min + ivec3(2, 0, fz);
        }
    }

    vec3 x0 = vec3(v0);
    vec3 x1 = vec3(v1);
    vec3 x2 = vec3(v2);
    vec3 x3 = vec3(v3);
    vec3 a = x1 - x0;
    vec3 b = x2 - x0;
    vec3 c = x3 - x0;
    vec3 r0 = cross(b, c);
    vec3 r1 = cross(c, a);
    vec3 r2 = cross(a, b);
    float det = dot(a, r0);
    if (abs(det) < 1e-6) {
        return;
    }

    vec3 xp = x - x0;
    vec3 uvw = vec3(dot(r0, xp), dot(r1, xp), dot(r2, xp)) / det;
    float w1 = uvw.x;
    float w2 = uvw.y;
    float w3 = uvw.z;
    float w0 = 1.0 - w1 - w2 - w3;
    w = vec4(w0, w1, w2, w3);

    gw1 = r0 / det;
    gw2 = r1 / det;
    gw3 = r2 / det;
    gw0 = -(gw1 + gw2 + gw3);
}

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }

    // Skip inactive particles (material_id==0).
    uint material_id = meta.data[p].x;
    if (material_id == 0u) {
        return;
    }

    vec3 x = pos_mass.data[p].xyz;
    float mass = max(0.0, pos_mass.data[p].w);
    vec3 v = vel_vol.data[p].xyz;
    float volume = max(0.0, vel_vol.data[p].w);

    mat3 C = c_in.data[p];
    mat3 F = f_in.data[p];
    float J = determinant(F);
    if (!(J > 0.0) || abs(J) < 1e-6) {
        F = mat3(1.0);
        J = 1.0;
    }

    vec2 lame = lame_for_material(material_id);
    float mu = lame.x;
    float lambda = lame.y;

    // Neo-Hookean first Piola stress.
    mat3 FinvT = transpose(inverse(F));
    float logJ = log(max(J, 1e-6));
    mat3 P = mu * (F - FinvT) + lambda * logJ * FinvT;

    float dt = max(0.0, u.grid_info.w);
    ivec3 v0, v1, v2, v3;
    vec4 w;
    vec3 gw0, gw1, gw2, gw3;
    compute_tetra(x, v0, v1, v2, v3, w, gw0, gw1, gw2, gw3);

    ivec3 cells[4] = ivec3[4](v0, v1, v2, v3);
    vec3 grads[4] = vec3[4](gw0, gw1, gw2, gw3);
    for (int i = 0; i < 4; i++) {
        ivec3 cell = cells[i];
        float wi = max(0.0, w[i]);
        if (wi <= 0.0) {
            continue;
        }
        if (!in_bounds(cell) || !bcc_parity(cell)) {
            continue;
        }
        uint gi = atlas_index_for_cell(cell);
        if (gi == 0u) {
            continue;
        }

        vec3 xi = vec3(cell);
        // Affine (APIC/MLS-MPM) transfer. Per-material scaling is baked into C in g2p.
        vec3 v_apic = v + C * (xi - x);
        vec3 momentum = (mass * wi) * v_apic;

        vec3 force = -(volume * (P * grads[i]));
        momentum += dt * force;

        int m_fixed = int(clamp((mass * wi) * FP_SCALE, 0.0, 2.0e9));
        int px = int(clamp(momentum.x * FP_SCALE, -2.0e9, 2.0e9));
        int py = int(clamp(momentum.y * FP_SCALE, -2.0e9, 2.0e9));
        int pz = int(clamp(momentum.z * FP_SCALE, -2.0e9, 2.0e9));

        atomicAdd(grid_accum.data[gi].x, m_fixed);
        atomicAdd(grid_accum.data[gi].y, px);
        atomicAdd(grid_accum.data[gi].z, py);
        atomicAdd(grid_accum.data[gi].w, pz);
    }
}
