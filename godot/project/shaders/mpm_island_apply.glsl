#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer ParticleVelVol {
    vec4 data[];
} vel_vol;

layout(set = 0, binding = 1, std430) buffer ParticleC {
    mat3 data[];
} c_buf;

layout(set = 0, binding = 2, std430) readonly buffer ParticlePosMass {
    vec4 data[];
} pos_mass;

layout(set = 0, binding = 3, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 4, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 5, std430) readonly buffer IslandComMass {
    vec4 data[];
} island_com_mass;

layout(set = 0, binding = 6, std430) readonly buffer IslandVel {
    vec4 data[];
} island_vel;

layout(set = 0, binding = 7, std430) readonly buffer IslandL {
    ivec4 data[];
} island_L;

layout(set = 0, binding = 8, std430) readonly buffer IslandI0 {
    ivec4 data[];
} island_I0;

layout(set = 0, binding = 9, std430) readonly buffer IslandI1 {
    ivec4 data[];
} island_I1;

const uint STONE_MATERIAL = 4u;
const float FP_SCALE = 10000.0;
const float SLEEP_V2 = 1e-4;
const float SLEEP_W2 = 1e-4;

mat3 skew(vec3 w) {
    return mat3(
        0.0, -w.z,  w.y,
        w.z,  0.0, -w.x,
       -w.y,  w.x,  0.0
    );
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
    uint island = meta.data[p].w;
    if (island == 0u) {
        island = p + 1u;
    }

    vec3 x = pos_mass.data[p].xyz;
    vec3 com = island_com_mass.data[island].xyz;
    vec3 vcom = island_vel.data[island].xyz;
    vec3 r = x - com;

    vec3 L = vec3(island_L.data[island].y, island_L.data[island].z, island_L.data[island].w) / FP_SCALE;

    vec4 I0 = vec4(island_I0.data[island]) / FP_SCALE;
    vec4 I1 = vec4(island_I1.data[island]) / FP_SCALE;
    float Ixx = I0.x;
    float Iyy = I0.y;
    float Izz = I0.z;
    float Ixy = I0.w;
    float Ixz = I1.x;
    float Iyz = I1.y;

    mat3 I = mat3(
        Ixx, Ixy, Ixz,
        Ixy, Iyy, Iyz,
        Ixz, Iyz, Izz
    );
    // Regularize to avoid singular inverse for tiny islands.
    I[0][0] += 1e-3;
    I[1][1] += 1e-3;
    I[2][2] += 1e-3;

    vec3 omega = inverse(I) * L;
    if (dot(vcom, vcom) < SLEEP_V2 && dot(omega, omega) < SLEEP_W2) {
        vel_vol.data[p].xyz = vec3(0.0);
        c_buf.data[p] = mat3(0.0);
        return;
    }
    vec3 v = vcom + cross(omega, r);

    vel_vol.data[p].xyz = v;
    c_buf.data[p] = skew(omega);
}
