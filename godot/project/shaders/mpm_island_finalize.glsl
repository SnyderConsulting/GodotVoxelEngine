#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer IslandMassMom {
    ivec4 data[];
} island_mass_mom;

layout(set = 0, binding = 1, std430) readonly buffer IslandMassCom {
    ivec4 data[];
} island_mass_com;

layout(set = 0, binding = 2, std430) buffer IslandComMass {
    vec4 data[];
} island_com_mass;

layout(set = 0, binding = 3, std430) buffer IslandVel {
    vec4 data[];
} island_vel;

const float FP_SCALE = 10000.0;

void main() {
    uint i = gl_GlobalInvocationID.x;
    // NOTE: This shader intentionally has no bounds check.
    // The caller must pad the island SSBO allocations to cover the rounded-up dispatch size
    // (e.g. ceil(island_count / 256) * 256). Otherwise this will go out-of-bounds and corrupt GPU memory.
    ivec4 mm = island_mass_mom.data[i];
    int m_fixed = mm.x;
    if (m_fixed <= 0) {
        island_com_mass.data[i] = vec4(0.0);
        island_vel.data[i] = vec4(0.0);
        return;
    }

    ivec4 mc = island_mass_com.data[i];
    vec3 com = vec3(mc.y, mc.z, mc.w) / float(m_fixed);
    vec3 vcom = vec3(mm.y, mm.z, mm.w) / float(m_fixed);
    float mass = float(m_fixed) / FP_SCALE;
    island_com_mass.data[i] = vec4(com, mass);
    island_vel.data[i] = vec4(vcom, 0.0);
}
