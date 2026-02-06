#version 450

layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer ParticleMeta {
    uvec4 data[];
} meta;

layout(set = 0, binding = 1, std430) readonly buffer ParticleCount {
    uint data[];
} particle_count;

layout(set = 0, binding = 2, std430) readonly buffer LabelsIn {
    uint data[];
} labels_in;

const uint STONE_MATERIAL = 4u;

void main() {
    uint p = gl_GlobalInvocationID.x;
    uint count = particle_count.data[0];
    if (p >= count) {
        return;
    }
    if (meta.data[p].x != STONE_MATERIAL) {
        meta.data[p].w = 0u;
        return;
    }
    uint lab = labels_in.data[p];
    if (lab == 0u) {
        meta.data[p].w = 0u;
        return;
    }
    meta.data[p].w = lab;
}
