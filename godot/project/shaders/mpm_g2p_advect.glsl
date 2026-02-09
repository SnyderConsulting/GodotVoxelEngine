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

layout(set = 0, binding = 2, std430) readonly buffer ParticlePosMassIn {
    vec4 data[];
} pos_mass_in;
layout(set = 0, binding = 3, std430) readonly buffer ParticleVelVolIn {
    vec4 data[];
} vel_vol_in;
layout(set = 0, binding = 4, std430) readonly buffer ParticleCIn {
    mat3 data[];
} c_in;
layout(set = 0, binding = 5, std430) readonly buffer ParticleFIn {
    mat3 data[];
} f_in;

layout(set = 0, binding = 6, std430) buffer ParticlePosMassOut {
    vec4 data[];
} pos_mass_out;
layout(set = 0, binding = 7, std430) buffer ParticleVelVolOut {
    vec4 data[];
} vel_vol_out;

layout(set = 0, binding = 8, std430) buffer ParticleCOut {
    mat3 data[];
} c_out;
layout(set = 0, binding = 9, std430) buffer ParticleFOut {
    mat3 data[];
} f_out;

layout(set = 0, binding = 10, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 11, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 12, std430) readonly buffer GridVel {
    vec4 data[];
} grid_vel;

layout(set = 0, binding = 13, std430) readonly buffer StaticAtlas {
    uint data[];
} static_atlas;

const uint FLAG_STATIC = 1u << 1;
// Inflate static solids slightly for collision to reduce leaking through thin voxel shells.
const float STATIC_COLLISION_MARGIN = 0.03;

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

float sdf_truncated_octahedron(vec3 p) {
    const float inv_sqrt3 = 0.57735026919;
    const float scale = 2.0;
    vec3 q = abs(p) * scale;
    float d1 = max(q.x, max(q.y, q.z)) - 2.0;
    float d2 = (q.x + q.y + q.z - 3.0) * inv_sqrt3;
    return max(d1, d2) / scale;
}

vec3 estimate_normal(vec3 p) {
    float e = 0.001;
    float dx = sdf_truncated_octahedron(p + vec3(e, 0.0, 0.0)) - sdf_truncated_octahedron(p - vec3(e, 0.0, 0.0));
    float dy = sdf_truncated_octahedron(p + vec3(0.0, e, 0.0)) - sdf_truncated_octahedron(p - vec3(0.0, e, 0.0));
    float dz = sdf_truncated_octahedron(p + vec3(0.0, 0.0, e)) - sdf_truncated_octahedron(p - vec3(0.0, 0.0, e));
    vec3 n = vec3(dx, dy, dz);
    float ln = length(n);
    if (ln < 1e-6) {
        // Deep inside solids the finite-difference gradient can be ~0 due to symmetry.
        // Fall back to a radial normal to push particles out deterministically.
        float lp = length(p);
        if (lp > 1e-6) {
            return p / lp;
        }
        return vec3(0.0, 1.0, 0.0);
    }
    return n / ln;
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

ivec3 snap_to_bcc(vec3 x);

bool query_static_sdf(vec3 x, out float dist, out vec3 normal) {
    // Approximate union SDF against static voxels by checking the nearest BCC cell and its 14 face neighbors.
    ivec3 base = snap_to_bcc(x);
    ivec3 offsets[15] = ivec3[15](
        ivec3(0, 0, 0),
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
    float best_d = 1e9;
    ivec3 best_cell = base;
    bool found = false;
    for (int i = 0; i < 15; i++) {
        ivec3 c = base + offsets[i];
        if (!in_bounds(c) || !bcc_parity(c)) {
            continue;
        }
        uint si = atlas_index_for_cell(c);
        if (si == 0u) {
            continue;
        }
        if (static_atlas.data[si] == 0u) {
            continue;
        }
        float d = sdf_truncated_octahedron(x - vec3(c)) - STATIC_COLLISION_MARGIN;
        if (d < best_d) {
            best_d = d;
            best_cell = c;
            found = true;
        }
    }
    if (!found) {
        dist = 1e9;
        normal = vec3(0.0, 1.0, 0.0);
        return false;
    }
    dist = best_d;
    normal = estimate_normal(x - vec3(best_cell));
    return true;
}

void material_params(uint material_id, out float shear_relax, out float damping, out float j_min, out float j_max) {
    if (material_id == 1u) { // sand
        // Sand should behave plastic, not like an elastic spring.
        // Strongly relax shear and keep volume changes bounded for stability.
        shear_relax = 0.85;
        damping = 0.995;
        // Keep sand closer to volume-preserving so piles don't collapse into a dense blob.
        j_min = 0.92;
        j_max = 1.08;
        return;
    }
    if (material_id == 2u) { // water
        shear_relax = 1.0;
        damping = 0.999;
        j_min = 0.90;
        j_max = 1.10;
        return;
    }
    if (material_id == 4u) { // stone
        // When fracture is disabled, keep stone near-rigid by aggressively removing shear
        // and tightly clamping volume changes. This prevents the classic MPM "melting/jitter"
        // artifact in the stability/jelly test.
        // fracture_enabled is encoded as u.world_rot_x.w (shared Params UBO slot).
        bool do_fracture = (u.world_rot_x.w > 0.5);
        if (!do_fracture) {
            shear_relax = 1.0;
            damping = 0.9995;
            j_min = 0.98;
            j_max = 1.02;
        } else {
            shear_relax = 0.0;
            damping = 0.9995;
            j_min = 0.80;
            j_max = 1.20;
        }
        return;
    }
    shear_relax = 0.0;
    damping = 0.999;
    j_min = 0.75;
    j_max = 1.25;
}

ivec3 clamp_cube_min(ivec3 cube_min) {
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
    ivec3 center = cube_min + ivec3(1, 1, 1);

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

    vec3 f = x - vec3(cube_min);
    float u2 = 0.0;
    float v2f = 0.0;
    if (axis == 0) {
        u2 = f.y;
        v2f = f.z;
    } else if (axis == 1) {
        u2 = f.x;
        v2f = f.z;
    } else {
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

ivec3 snap_to_bcc(vec3 x) {
    // Nearest even-even-even or odd-odd-odd lattice point.
    ivec3 even = ivec3(round(x * 0.5)) * 2;
    ivec3 odd = ivec3(round((x - vec3(1.0)) * 0.5)) * 2 + ivec3(1, 1, 1);
    float de = length(x - vec3(even));
    float d_odd = length(x - vec3(odd));
    ivec3 c = (d_odd < de) ? odd : even;
    c = clamp(c, ivec3(0), ivec3(int(u.grid_info.x) - 1, int(u.grid_info.y) - 1, int(u.grid_info.z) - 1));
    if (bcc_parity(c)) {
        return c;
    }
    // Fallback: force parity by nudging towards bounds.
    ivec3 c2 = c;
    c2.x = clamp(c2.x + 1, 0, int(u.grid_info.x) - 1);
    if (bcc_parity(c2)) return c2;
    c2 = c;
    c2.y = clamp(c2.y + 1, 0, int(u.grid_info.y) - 1);
    if (bcc_parity(c2)) return c2;
    c2 = c;
    c2.z = clamp(c2.z + 1, 0, int(u.grid_info.z) - 1);
    if (bcc_parity(c2)) return c2;
    return c;
}

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }
    uint material_id = meta.data[p].x;
    uint flags = meta.data[p].y;
    if (material_id == 0u) {
        pos_mass_out.data[p] = pos_mass_in.data[p];
        vel_vol_out.data[p] = vel_vol_in.data[p];
        c_out.data[p] = c_in.data[p];
        f_out.data[p] = f_in.data[p];
        return;
    }
    if ((flags & FLAG_STATIC) != 0u) {
        // Static/bedrock particles participate in topology (bonds/CCL) but do not advect.
        pos_mass_out.data[p] = pos_mass_in.data[p];
        vel_vol_out.data[p] = vec4(0.0, 0.0, 0.0, vel_vol_in.data[p].w);
        c_out.data[p] = mat3(0.0);
        f_out.data[p] = f_in.data[p];
        return;
    }

    vec3 x = pos_mass_in.data[p].xyz;
    float mass = max(0.0, pos_mass_in.data[p].w);
    vec3 v_prev = vel_vol_in.data[p].xyz;
    float vol = max(0.0, vel_vol_in.data[p].w);

    mat3 F = f_in.data[p];
    float J0 = determinant(F);
    if (!(J0 > 0.0) || abs(J0) < 1e-6) {
        F = mat3(1.0);
        J0 = 1.0;
    }

    float shear_relax = 0.0;
    float damping = 0.999;
    float j_min = 0.75;
    float j_max = 1.25;
    material_params(material_id, shear_relax, damping, j_min, j_max);

    ivec3 v0, v1, v2, v3;
    vec4 w;
    vec3 gw0, gw1, gw2, gw3;
    compute_tetra(x, v0, v1, v2, v3, w, gw0, gw1, gw2, gw3);

    ivec3 cells[4] = ivec3[4](v0, v1, v2, v3);
    vec3 grads[4] = vec3[4](gw0, gw1, gw2, gw3);

    vec3 v = vec3(0.0);
    mat3 C = mat3(0.0);
    for (int i = 0; i < 4; i++) {
        ivec3 cell = cells[i];
        if (!in_bounds(cell) || !bcc_parity(cell)) {
            continue;
        }
        uint gi = atlas_index_for_cell(cell);
        if (gi == 0u) {
            continue;
        }
        vec3 vi = grid_vel.data[gi].xyz;
        v += max(0.0, w[i]) * vi;
        C += outerProduct(vi, grads[i]);
    }

    v *= damping;
    C *= damping;

    // Safety clamp: prevents single-cell blow-ups from turning into huge particle velocities.
    float pvmax = 120.0;
    float pvm = length(v);
    if (pvm > pvmax) {
        v *= pvmax / pvm;
    }

    float dt = max(0.0, u.grid_info.w);
    // Clamp to simulation bounds (grid space).
    vec3 minp = vec3(1.0);
    vec3 maxp = vec3(u.grid_info.xyz - vec3(3.0));

    // Friction depends on material.
    float mu = 0.35;
    if (material_id == 1u) { // sand
        mu = 0.55;
    } else if (material_id == 2u) { // water
        mu = 0.05;
    }

    // Collision-aware advection (micro-steps) to reduce tunneling through thin glass.
    // Uses conservative step clamping based on the static SDF at the current position.
    const int COLLIDE_STEPS = 8;
    const float SKIN = 0.02;
    float dtc = dt / float(COLLIDE_STEPS);
    vec3 x_step = x;
    bool hard_hit = false;
    for (int s = 0; s < COLLIDE_STEPS; s++) {
        vec3 x_prev = x_step;
        vec3 dx = v * dtc;
        float step_len = length(dx);
        vec3 dir = (step_len > 1e-6) ? (dx / step_len) : vec3(0.0);

        // Conservative advancement: limit displacement so we don't cross the SDF surface in one step.
        float sd0 = 0.0;
        vec3 n0 = vec3(0.0, 1.0, 0.0);
        if (step_len > 1e-6 && query_static_sdf(x_step, sd0, n0)) {
            if (sd0 < SKIN) {
                // Already contacting/inside: push out and remove normal velocity.
                x_step = x_step + (SKIN - sd0) * n0;
                x_step = clamp(x_step, minp, maxp);
                float vn0 = dot(v, n0);
                if (vn0 < 0.0) {
                    v = v - vn0 * n0;
                }
                vec3 vt0 = v - dot(v, n0) * n0;
                v = v - vt0 * clamp(mu, 0.0, 0.95);
                C = mat3(0.0);
                // Small extra damping at contact to reduce jitter.
                v *= 0.85;
                continue;
            }
            float max_step = max(0.0, sd0 - SKIN);
            if (step_len > max_step) {
                step_len = max_step;
                dx = dir * step_len;
            }
        }

        vec3 x_try = x_step + dx;
        x_try = clamp(x_try, minp, maxp);

        float sd = 0.0;
        vec3 n = vec3(0.0, 1.0, 0.0);
        if (query_static_sdf(x_try, sd, n) && sd < SKIN) {
            x_try = x_try + (SKIN - sd) * n;

            float vn = dot(v, n);
            if (vn < 0.0) {
                v = v - vn * n;
            }

            vec3 vt = v - dot(v, n) * n;
            v = v - vt * clamp(mu, 0.0, 0.95);
            C = mat3(0.0);
            v *= 0.9;
        } else {
            // Discrete fallback.
            ivec3 cell = snap_to_bcc(x_try);
            if (in_bounds(cell) && bcc_parity(cell)) {
                uint si = atlas_index_for_cell(cell);
                if (si != 0u && static_atlas.data[si] != 0u) {
                    x_try = x_prev;
                    v = vec3(0.0);
                    C = mat3(0.0);
                    hard_hit = true;
                    break;
                }
            }
        }

        x_step = clamp(x_try, minp, maxp);
    }

    vec3 x_new = x_step;

    // Deformation gradient update (after collision may have zeroed C).
    F = (mat3(1.0) + dt * C) * F;

    // Simple shear-yield: relax towards isotropic scaling.
    float J = determinant(F);
    if (!(J > 0.0) || abs(J) < 1e-6) {
        F = mat3(1.0);
        J = 1.0;
    }
    J = clamp(J, j_min, j_max);
    float sJ = pow(J, 1.0 / 3.0);
    mat3 F_iso = mat3(sJ, 0.0, 0.0,
                      0.0, sJ, 0.0,
                      0.0, 0.0, sJ);
    float relax = clamp(shear_relax, 0.0, 1.0);
    F = F * (1.0 - relax) + F_iso * relax;

    if (hard_hit) {
        // If we hit a discrete static voxel, keep the prior deformation state for stability.
        F = f_in.data[p];
    }

    pos_mass_out.data[p] = vec4(x_new, mass);
    vel_vol_out.data[p] = vec4(v, vol);
    c_out.data[p] = C;
    f_out.data[p] = F;
}
