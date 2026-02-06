#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer ParticlePosMass {
    vec4 data[];
} pos_mass;

layout(set = 0, binding = 1, std430) readonly buffer ParticleVelVol {
    vec4 data[];
} vel_vol;

layout(set = 0, binding = 2, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 3, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 4, std430) readonly buffer IslandComMass {
    vec4 data[];
} island_com_mass;

layout(set = 0, binding = 5, std430) readonly buffer IslandVel {
    vec4 data[];
} island_vel;

layout(set = 0, binding = 6, std430) buffer IslandL {
    ivec4 data[];
} island_L;

layout(set = 0, binding = 7, std430) buffer IslandI0 {
    ivec4 data[];
} island_I0;

layout(set = 0, binding = 8, std430) buffer IslandI1 {
    ivec4 data[];
} island_I1;

const uint STONE_MATERIAL = 4u;
const float FP_SCALE = 10000.0;

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
    float m = max(0.0, pos_mass.data[p].w);
    vec3 v = vel_vol.data[p].xyz;

    vec3 com = island_com_mass.data[island].xyz;
    vec3 vcom = island_vel.data[island].xyz;

    vec3 r = x - com;
    vec3 vrel = v - vcom;
    vec3 L = m * cross(r, vrel);

    float rx = r.x;
    float ry = r.y;
    float rz = r.z;
    float Ixx = m * (ry * ry + rz * rz);
    float Iyy = m * (rx * rx + rz * rz);
    float Izz = m * (rx * rx + ry * ry);
    float Ixy = -m * (rx * ry);
    float Ixz = -m * (rx * rz);
    float Iyz = -m * (ry * rz);

    int Lx = int(clamp(L.x * FP_SCALE, -2.0e9, 2.0e9));
    int Ly = int(clamp(L.y * FP_SCALE, -2.0e9, 2.0e9));
    int Lz = int(clamp(L.z * FP_SCALE, -2.0e9, 2.0e9));

    atomicAdd(island_L.data[island].y, Lx);
    atomicAdd(island_L.data[island].z, Ly);
    atomicAdd(island_L.data[island].w, Lz);

    atomicAdd(island_I0.data[island].x, int(clamp(Ixx * FP_SCALE, -2.0e9, 2.0e9)));
    atomicAdd(island_I0.data[island].y, int(clamp(Iyy * FP_SCALE, -2.0e9, 2.0e9)));
    atomicAdd(island_I0.data[island].z, int(clamp(Izz * FP_SCALE, -2.0e9, 2.0e9)));
    atomicAdd(island_I0.data[island].w, int(clamp(Ixy * FP_SCALE, -2.0e9, 2.0e9)));
    atomicAdd(island_I1.data[island].x, int(clamp(Ixz * FP_SCALE, -2.0e9, 2.0e9)));
    atomicAdd(island_I1.data[island].y, int(clamp(Iyz * FP_SCALE, -2.0e9, 2.0e9)));
}

