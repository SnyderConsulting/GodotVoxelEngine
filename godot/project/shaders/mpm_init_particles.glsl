#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 1, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 2, std430) buffer ParticleCA {
    mat3 data[];
} c_a;

layout(set = 0, binding = 3, std430) buffer ParticleFA {
    mat3 data[];
} f_a;

layout(set = 0, binding = 4, std430) buffer ParticleCB {
    mat3 data[];
} c_b;

layout(set = 0, binding = 5, std430) buffer ParticleFB {
    mat3 data[];
} f_b;

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }
    if (meta.data[p].x == 0u) {
        return;
    }
    c_a.data[p] = mat3(0.0);
    c_b.data[p] = mat3(0.0);
    f_a.data[p] = mat3(1.0);
    f_b.data[p] = mat3(1.0);
}

