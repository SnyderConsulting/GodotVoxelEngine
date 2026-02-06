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

layout(set = 0, binding = 4, std430) buffer IslandMassMom {
    ivec4 data[];
} island_mass_mom;

layout(set = 0, binding = 5, std430) buffer IslandMassCom {
    ivec4 data[];
} island_mass_com;

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

    int m_fixed = int(clamp(m * FP_SCALE, 0.0, 2.0e9));
    int px = int(clamp((m * v.x) * FP_SCALE, -2.0e9, 2.0e9));
    int py = int(clamp((m * v.y) * FP_SCALE, -2.0e9, 2.0e9));
    int pz = int(clamp((m * v.z) * FP_SCALE, -2.0e9, 2.0e9));
    int cx = int(clamp((m * x.x) * FP_SCALE, -2.0e9, 2.0e9));
    int cy = int(clamp((m * x.y) * FP_SCALE, -2.0e9, 2.0e9));
    int cz = int(clamp((m * x.z) * FP_SCALE, -2.0e9, 2.0e9));

    atomicAdd(island_mass_mom.data[island].x, m_fixed);
    atomicAdd(island_mass_mom.data[island].y, px);
    atomicAdd(island_mass_mom.data[island].z, py);
    atomicAdd(island_mass_mom.data[island].w, pz);

    atomicAdd(island_mass_com.data[island].x, m_fixed);
    atomicAdd(island_mass_com.data[island].y, cx);
    atomicAdd(island_mass_com.data[island].z, cy);
    atomicAdd(island_mass_com.data[island].w, cz);
}

