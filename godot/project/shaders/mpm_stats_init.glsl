#version 450

// Initialize the MPM stats buffer with sentinel values for atomicMin/atomicMax reductions.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) buffer StatsOut {
    int data[];
} stats_out;

// Must match the parsing/layout in VoxelRenderer.gd.
const int STATS_VERSION = 1;
const int MAT_SLOTS = 16;

// Header
const int IDX_VERSION = 0;
const int IDX_PARTICLE_COUNT = 1;
const int IDX_ACTIVE_COUNT = 2;
const int IDX_INACTIVE_COUNT = 3;
const int IDX_NAN_COUNT = 4;
const int IDX_BASE = 5;

// Per-slot block (ints)
// [count, mass_sum_fixed, sum_speed_x100, max_speed_x1000, overlap_static,
//  min_x,min_y,min_z, max_x,max_y,max_z, sum_mx,sum_my,sum_mz]
const int SLOT_STRIDE = 14;

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint total = uint(IDX_BASE + MAT_SLOTS * SLOT_STRIDE);
    if (i >= total) {
        return;
    }

    int idx = int(i);
    if (idx == IDX_VERSION) {
        stats_out.data[idx] = STATS_VERSION;
        return;
    }
    if (idx >= IDX_PARTICLE_COUNT && idx <= IDX_NAN_COUNT) {
        stats_out.data[idx] = 0;
        return;
    }

    // Per-slot init.
    int rel = idx - IDX_BASE;
    int off = rel % SLOT_STRIDE;
    // min_* fields need +INF; max_* need -INF.
    if (off >= 5 && off <= 7) { // min_x,min_y,min_z
        stats_out.data[idx] = 2147483647;
        return;
    }
    if (off >= 8 && off <= 10) { // max_x,max_y,max_z
        stats_out.data[idx] = -2147483647;
        return;
    }
    stats_out.data[idx] = 0;
}

