#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std140) uniform Params {
    vec4 grid_info;   // xyz = grid size
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

layout(set = 0, binding = 2, std430) readonly buffer AtlasIn {
    uint data[];
} atlas_in;

layout(set = 0, binding = 3, std430) buffer AtlasOut {
    uint data[];
} atlas_out;

layout(set = 0, binding = 4, std430) readonly buffer ActiveList {
    uint data[];
} active_list;
layout(set = 0, binding = 5, std430) readonly buffer SeedIn {
    uint data[];
} seed_in;
layout(set = 0, binding = 6, std430) buffer SeedOut {
    uint data[];
} seed_out;
layout(set = 0, binding = 7, std430) readonly buffer MaterialProps {
    vec4 data[];
} material_props;

const uint GLASS_MATERIAL = 8u;
const uint INVISIBLE_MATERIAL = 9u;
const uint WATER_MATERIAL = 2u;
const uint OXYGEN_MATERIAL = 3u;
const uint FIRE_MATERIAL = 5u;
const uint MATERIAL_PROPS_STRIDE = 5u;
// Seed packing: upper 16 bits are metadata, low 16 bits are "wealth" (kinetic energy proxy).
// Bit 31 marks a voxel as "settled"/sleeping: it will not simulate until woken by a CPU-side edit.
const uint SEED_SLEEP_BIT = 0x80000000u;
const uint SEED_META_RANDOM_MASK = 0x7FFF0000u;

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

uint hash_cell(ivec3 c, uint seed) {
    return uint(c.x * 73856093 ^ c.y * 19349663 ^ c.z * 83492791) ^ seed;
}

ivec3 brick_from_index(uint brick_index) {
    uint bx = brick_index % uint(u.brick_info.x);
    uint by = (brick_index / uint(u.brick_info.x)) % uint(u.brick_info.y);
    uint bz = brick_index / (uint(u.brick_info.x) * uint(u.brick_info.y));
    return ivec3(int(bx), int(by), int(bz));
}

void main() {
    const uint LOCAL_SIZE = 4u;
    uint brick_size = uint(u.brick_info.w);
    uint groups_per_brick = (brick_size + LOCAL_SIZE - 1u) / LOCAL_SIZE;
    if (groups_per_brick == 0u) {
        return;
    }
    uint brick_list_index = gl_WorkGroupID.x / groups_per_brick;
    uint tile_x = gl_WorkGroupID.x - brick_list_index * groups_per_brick;
    uint tile_y = gl_WorkGroupID.y;
    uint tile_z = gl_WorkGroupID.z;
    if (tile_y >= groups_per_brick || tile_z >= groups_per_brick) {
        return;
    }
    uint brick_index = active_list.data[brick_list_index];
    ivec3 brick = brick_from_index(brick_index);
    uvec3 local_id = gl_LocalInvocationID.xyz;
    uint lx = tile_x * LOCAL_SIZE + local_id.x;
    uint ly = tile_y * LOCAL_SIZE + local_id.y;
    uint lz = tile_z * LOCAL_SIZE + local_id.z;
    if (lx >= brick_size || ly >= brick_size || lz >= brick_size) {
        return;
    }
    ivec3 cell = brick * int(brick_size) + ivec3(int(lx), int(ly), int(lz));
    if (!in_bounds(cell)) {
        return;
    }
    if (!bcc_parity(cell)) {
        return;
    }
    uint self_idx = atlas_index_for_cell(cell);
    if (self_idx == 0u) {
        return;
    }
    uint material = atlas_in.data[self_idx];
    if (material == 0u) {
        return;
    }
    bool is_water = material == WATER_MATERIAL;
    bool is_fire = material == FIRE_MATERIAL;
    uint seed = seed_in.data[self_idx];
    // Treat fire as a fixed, placeable light source in the prototype (no drift/dissipation).
    if (material == GLASS_MATERIAL || material == INVISIBLE_MATERIAL || material == FIRE_MATERIAL) {
        if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
            seed_out.data[self_idx] = 0u;
        }
        return;
    }
    bool is_sleeping = (seed & SEED_SLEEP_BIT) != 0u;
    // Settled voxels are "frozen" until a CPU edit wakes them by clearing SEED_SLEEP_BIT.
    // This prevents freshly generated terrain from collapsing immediately.
    if (is_sleeping) {
        if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
            // Keep metadata, force wealth to 0.
            seed_out.data[self_idx] = (seed & SEED_META_RANDOM_MASK) | SEED_SLEEP_BIT;
        }
        return;
    }

    vec3 gravity = u.debug_info.xyz;
    if (length(gravity) < 1e-3) {
        gravity = vec3(0.0, -1.0, 0.0);
    }
    gravity = normalize(gravity);
    vec3 motion_gravity = gravity;
    if (is_fire) {
        // Fire drifts opposite gravity while still using the same material model.
        motion_gravity = -gravity;
    }

    uint mat_index = material * MATERIAL_PROPS_STRIDE;
    vec4 props0 = material_props.data[mat_index + 0u];
    vec4 props1 = material_props.data[mat_index + 1u];
    float mass = props0.x;
    float friction = props0.y;
    float cohesion = props0.z;
    float resistance = props0.w;
    float drag = props1.x;
    float support_bonus = props1.y;
    float lateral_bias = props1.z;
    float gravity_bias = props1.w;
    float wealth = float(seed & 0xFFFFu) / 256.0;

    const int NEIGHBOR_COUNT = 14;
    ivec3 offsets[NEIGHBOR_COUNT] = ivec3[NEIGHBOR_COUNT](
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
    float gravity_align[NEIGHBOR_COUNT];
    for (int i = 0; i < NEIGHBOR_COUNT; i++) {
        gravity_align[i] = dot(vec3(offsets[i]), motion_gravity);
    }
    int down_index = 0;
    float down_best = -1e9;
    for (int i = 0; i < NEIGHBOR_COUNT; i++) {
        if (gravity_align[i] > down_best) {
            down_best = gravity_align[i];
            down_index = i;
        }
    }
    int color_phase = int(u.debug_info.w) & 3;
    if (((cell.x + cell.y + cell.z) & 3) != color_phase) {
        // Not this phase: preserve current state.
        if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
            seed_out.data[self_idx] = seed;
        }
        return;
    }

    int like_count = 0;
    int occupied_count = 0;
    int air_count = 0;
    int glass_count = 0;
    bool supported = false;
    bool down_is_sand = false;
    for (int i = 0; i < NEIGHBOR_COUNT; i++) {
        ivec3 n = cell + offsets[i];
        if (!in_bounds(n) || !bcc_parity(n)) {
            continue;
        }
        uint n_idx = atlas_index_for_cell(n);
        if (n_idx == 0u) {
            continue;
        }
        uint n_mat = atlas_in.data[n_idx];
        uint n_mat_effective = n_mat == 0u ? OXYGEN_MATERIAL : n_mat;
        if (n_mat == 0u || n_mat == OXYGEN_MATERIAL) {
            air_count++;
        } else if (n_mat == GLASS_MATERIAL) {
            glass_count++;
        } else {
            occupied_count++;
            if (n_mat_effective == material) {
                like_count++;
            }
        }
        if (i == down_index && n_mat != 0u) {
            supported = true;
            if (n_mat == 1u) {
                down_is_sand = true;
            }
        }
    }
    // Pressure proxy: count same-material voxels above along dominant gravity axis.
    ivec3 gstep = ivec3(0, 0, 0);
    vec3 gabs = abs(motion_gravity);
    if (gabs.x >= gabs.y && gabs.x >= gabs.z) {
        gstep = ivec3(motion_gravity.x >= 0.0 ? 2 : -2, 0, 0);
    } else if (gabs.y >= gabs.x && gabs.y >= gabs.z) {
        gstep = ivec3(0, motion_gravity.y >= 0.0 ? 2 : -2, 0);
    } else {
        gstep = ivec3(0, 0, motion_gravity.z >= 0.0 ? 2 : -2);
    }
    ivec3 up_step = -gstep;
    int self_pressure = 0;
    int self_below = 0;
    ivec3 scan = cell;
    for (int s = 0; s < 16; s++) {
        scan += up_step;
        if (!in_bounds(scan) || !bcc_parity(scan)) {
            break;
        }
        uint s_idx = atlas_index_for_cell(scan);
        if (s_idx == 0u) {
            break;
        }
        if (atlas_in.data[s_idx] == material) {
            self_pressure += 1;
        } else {
            break;
        }
    }
    scan = cell;
    for (int s = 0; s < 16; s++) {
        scan += gstep;
        if (!in_bounds(scan) || !bcc_parity(scan)) {
            break;
        }
        uint s_idx = atlas_index_for_cell(scan);
        if (s_idx == 0u) {
            break;
        }
        if (atlas_in.data[s_idx] == material) {
            self_below += 1;
        } else {
            break;
        }
    }
    int self_column = self_pressure + self_below + 1;

    // Soft compressibility: give liquids a small extra pressure head.
    if (is_water) {
        self_pressure += 2;
    }
    float base_height = -dot(vec3(cell), motion_gravity);
    float surface_height = -dot(vec3(cell + up_step * self_pressure), motion_gravity);
    float cohesion_scale = is_water ? 0.6 : 1.0;
    if (is_water && down_is_sand) {
        cohesion_scale = 0.4;
    }
    float comfort = -base_height * gravity_bias + float(like_count) * cohesion * cohesion_scale;
    if (supported) {
        comfort += support_bonus;
    }
    float pressure_penalty = 0.12 + resistance * 0.08;
    comfort -= float(occupied_count) * pressure_penalty;
    comfort -= float(self_pressure) * (0.3 + resistance * 0.2);
    if (is_water) {
        // Surface tension: penalize exposed faces to encourage pooling.
        float surface_penalty = float(air_count) * 0.4;
        // Slight wetting on glass to avoid complete beading.
        float adhesion_bonus = float(glass_count) * 0.05;
        comfort -= surface_penalty;
        comfort += adhesion_bonus;
    }

    float best_incentive = 0.0;
    ivec3 best_offset = ivec3(0);
    bool best_swap = false;
    uint best_target_mat = 0u;
    float best_down = 0.0;
    float max_lateral_dp = -1e9;

    // Hard gravity step: if a direct down move is available, take it.
    ivec3 down_offset = offsets[down_index];
    ivec3 down_target = cell + down_offset;
    if (in_bounds(down_target) && bcc_parity(down_target)) {
        uint d_idx = atlas_index_for_cell(down_target);
        if (d_idx != 0u) {
            uint d_mat = atlas_in.data[d_idx];
            if (d_mat == 0u) {
                if (atomicCompSwap(atlas_out.data[d_idx], 0u, material) == 0u) {
                    float down_gain = max(0.0, gravity_align[down_index]) * mass * 0.35;
                    float new_wealth = max(0.0, wealth + down_gain - drag);
                    uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
                    seed_out.data[d_idx] = new_seed;
                    return;
                }
            } else {
                // Swap down if we can displace the target.
                if ((seed_in.data[d_idx] & SEED_SLEEP_BIT) == 0u) {
                    uint t_index = d_mat * MATERIAL_PROPS_STRIDE;
                    vec4 t_props0 = material_props.data[t_index + 0u];
                    float t_resistance = t_props0.w;
                    if (wealth > t_resistance) {
                        if (atomicCompSwap(atlas_out.data[d_idx], 0u, material) == 0u
                            && atomicCompSwap(atlas_out.data[self_idx], 0u, d_mat) == 0u) {
                            float new_wealth = max(0.0, wealth - t_resistance - drag);
                            uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
                            seed_out.data[d_idx] = new_seed;
                            seed_out.data[self_idx] = 0u;
                            return;
                        }
                    }
                }
            }
        }
    }

    // Water lateral equalization: pick the lowest column neighbor and move there if it reduces pressure.
    if (is_water) {
        float best_surface = surface_height;
        ivec3 best_eq_offset = ivec3(0);
        uint best_eq_idx = 0u;
        for (int i = 0; i < NEIGHBOR_COUNT; i++) {
            if (gravity_align[i] > 0.0) {
                continue;
            }
            ivec3 offset = offsets[i];
            ivec3 target = cell + offset;
            if (!in_bounds(target) || !bcc_parity(target)) {
                continue;
            }
            uint t_idx = atlas_index_for_cell(target);
            if (t_idx == 0u) {
                continue;
            }
            if (atlas_in.data[t_idx] != 0u) {
                continue;
            }
            int target_pressure = 0;
            int target_below = 0;
            ivec3 scan_t = target;
            for (int s = 0; s < 16; s++) {
                scan_t += up_step;
                if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                    break;
                }
                uint t_idx2 = atlas_index_for_cell(scan_t);
                if (t_idx2 == 0u) {
                    break;
                }
                if (atlas_in.data[t_idx2] == material) {
                    target_pressure += 1;
                } else {
                    break;
                }
            }
            scan_t = target;
            for (int s = 0; s < 16; s++) {
                scan_t += gstep;
                if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                    break;
                }
                uint t_idx2 = atlas_index_for_cell(scan_t);
                if (t_idx2 == 0u) {
                    break;
                }
                if (atlas_in.data[t_idx2] == material) {
                    target_below += 1;
                } else {
                    break;
                }
            }
            float target_surface_height = -dot(vec3(target + up_step * target_pressure), motion_gravity);
            if (target_surface_height + 0.5 < best_surface) {
                best_surface = target_surface_height;
                best_eq_offset = offset;
                best_eq_idx = t_idx;
            }
        }
        if (best_eq_idx == 0u) {
            // Second-ring search: allow a 2-hop lateral move through water to reach a lower column.
            for (int i = 0; i < NEIGHBOR_COUNT; i++) {
                if (gravity_align[i] > 0.0) {
                    continue;
                }
                ivec3 step1 = offsets[i];
                ivec3 mid = cell + step1;
                if (!in_bounds(mid) || !bcc_parity(mid)) {
                    continue;
                }
                uint mid_idx = atlas_index_for_cell(mid);
                if (mid_idx == 0u) {
                    continue;
                }
                if (atlas_in.data[mid_idx] != material) {
                    continue;
                }
                // Require the intermediate water cell to be awake; sleeping voxels are rigid obstacles.
                if ((seed_in.data[mid_idx] & SEED_SLEEP_BIT) != 0u) {
                    continue;
                }
                for (int j = 0; j < NEIGHBOR_COUNT; j++) {
                    if (gravity_align[j] > 0.0) {
                        continue;
                    }
                    ivec3 step2 = offsets[j];
                    ivec3 hop = mid + step2;
                    if (!in_bounds(hop) || !bcc_parity(hop)) {
                        continue;
                    }
                    uint hop_idx = atlas_index_for_cell(hop);
                    if (hop_idx == 0u) {
                        continue;
                    }
                    if (atlas_in.data[hop_idx] != 0u) {
                        continue;
                    }
                    int target_pressure = 0;
                    int target_below = 0;
                    ivec3 scan_t = hop;
                    for (int s = 0; s < 16; s++) {
                        scan_t += up_step;
                        if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                            break;
                        }
                        uint t_idx2 = atlas_index_for_cell(scan_t);
                        if (t_idx2 == 0u) {
                            break;
                        }
                        if (atlas_in.data[t_idx2] == material) {
                            target_pressure += 1;
                        } else {
                            break;
                        }
                    }
                    scan_t = hop;
                    for (int s = 0; s < 16; s++) {
                        scan_t += gstep;
                        if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                            break;
                        }
                        uint t_idx2 = atlas_index_for_cell(scan_t);
                        if (t_idx2 == 0u) {
                            break;
                        }
                        if (atlas_in.data[t_idx2] == material) {
                            target_below += 1;
                        } else {
                            break;
                        }
                    }
                    float target_surface_height = -dot(vec3(hop + up_step * target_pressure), motion_gravity);
                    if (target_surface_height + 0.5 < best_surface) {
                        best_surface = target_surface_height;
                        best_eq_offset = step1 + step2;
                        best_eq_idx = hop_idx;
                    }
                }
            }
        }
        if (best_eq_idx != 0u) {
            if (best_surface >= surface_height - 0.75) {
                best_eq_idx = 0u;
            }
        }
        if (best_eq_idx != 0u) {
            if (atomicCompSwap(atlas_out.data[best_eq_idx], 0u, material) == 0u) {
                float new_wealth = max(0.0, wealth - drag);
                uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
                seed_out.data[best_eq_idx] = new_seed;
                return;
            }
        }
    }

    for (int i = 0; i < NEIGHBOR_COUNT; i++) {
        ivec3 offset = offsets[i];
        ivec3 target = cell + offset;
        if (!in_bounds(target) || !bcc_parity(target)) {
            continue;
        }
        uint t_idx = atlas_index_for_cell(target);
        if (t_idx == 0u) {
            continue;
        }
        uint t_mat = atlas_in.data[t_idx];
        float down = gravity_align[i];
        float target_height = -dot(vec3(target), motion_gravity);
        float height_drop = base_height - target_height;
        // Compute target pressure for equalization.
        int target_pressure = 0;
        int target_below = 0;
        ivec3 scan_t = target;
        for (int s = 0; s < 16; s++) {
            scan_t += up_step;
            if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                break;
            }
            uint t_idx2 = atlas_index_for_cell(scan_t);
            if (t_idx2 == 0u) {
                break;
            }
            if (atlas_in.data[t_idx2] == material) {
                target_pressure += 1;
            } else {
                break;
            }
        }
        scan_t = target;
        for (int s = 0; s < 16; s++) {
            scan_t += gstep;
            if (!in_bounds(scan_t) || !bcc_parity(scan_t)) {
                break;
            }
            uint t_idx2 = atlas_index_for_cell(scan_t);
            if (t_idx2 == 0u) {
                break;
            }
            if (atlas_in.data[t_idx2] == material) {
                target_below += 1;
            } else {
                break;
            }
        }
        int target_column = target_pressure + target_below + 1;
        float target_surface_height = -dot(vec3(target + up_step * target_pressure), motion_gravity);
        float target_comfort = -target_height * gravity_bias;
        float gain = target_comfort - comfort + down * gravity_bias * 0.5;
        // Pressure equalization: prefer moves toward lower pressure columns.
        float dp = is_water ? (surface_height - target_surface_height) : float(self_pressure - target_pressure);
        float pressure_gain = dp * (is_water ? 3.0 : (1.8 + resistance * 0.4));
        gain += pressure_gain;
        float move_cost = friction + drag;
        if (down <= 0.0) {
            move_cost -= lateral_bias;
            int target_air_preview = 0;
            if (is_water) {
                for (int j = 0; j < NEIGHBOR_COUNT; j++) {
                    ivec3 nn = target + offsets[j];
                    if (!in_bounds(nn) || !bcc_parity(nn)) {
                        continue;
                    }
                    uint nn_idx = atlas_index_for_cell(nn);
                    if (nn_idx == 0u) {
                        continue;
                    }
                    uint nn_mat = atlas_in.data[nn_idx];
                    if (nn_mat == 0u || nn_mat == OXYGEN_MATERIAL) {
                        target_air_preview++;
                    }
                }
                if (dp < 1.0 && height_drop <= 0.5 && !down_is_sand && target_air_preview >= air_count) {
                    continue;
                }
            }
            if (is_water && t_mat == 0u) {
                max_lateral_dp = max(max_lateral_dp, dp);
            }
            // Only allow sideways moves if we have positive pressure drop (avoid endless scatter).
            if (dp <= 0 && !(is_water && down_is_sand) && !(is_water && height_drop > 0.5)
                && !(is_water && target_air_preview < air_count)) {
                continue;
            }
            if (is_water) {
                // Settling threshold: ignore tiny pressure gradients to reduce jitter.
                if (dp < 0.75 && !down_is_sand && height_drop <= 0.5) {
                    continue;
                }
                // Strong override: if pressure is higher here, make sideways cheap and highly preferred.
                move_cost = 0.0;
                gain += float(dp) * 3.0;
                // Flattening override: force lateral flow when pressure difference is significant.
                gain = max(gain, float(dp) * 2.0);
                if (down_is_sand) {
                    gain += 0.6;
                }
                if (dp >= 1) {
                    gain += 1.0;
                }
                if (height_drop > 0.5) {
                    gain += height_drop * 1.5;
                }
                // Pressure tunnel: if we can see empty space in this direction, boost hard.
                float tunnel_bonus = 0.0;
                for (int h = 1; h <= 4; h++) {
                    ivec3 hop = target + offset * h;
                    if (!in_bounds(hop) || !bcc_parity(hop)) {
                        break;
                    }
                    uint h_idx = atlas_index_for_cell(hop);
                    if (h_idx == 0u) {
                        break;
                    }
                    if (atlas_in.data[h_idx] == 0u) {
                        tunnel_bonus = 2.2 + float(4 - h) * 0.5;
                        break;
                    }
                }
                gain += tunnel_bonus;
                // Pressure teleport: if blocked by water, hop through contiguous water to nearest empty.
                if (t_mat == material) {
                    ivec3 teleport = target;
                    uint teleport_idx = 0u;
                    bool blocked = false;
                    for (int h = 1; h <= 4; h++) {
                        ivec3 hop = cell + offset * (h + 1);
                        if (!in_bounds(hop) || !bcc_parity(hop)) {
                            blocked = true;
                            break;
                        }
                        uint h_idx = atlas_index_for_cell(hop);
                        if (h_idx == 0u) {
                            blocked = true;
                            break;
                        }
                        uint h_mat = atlas_in.data[h_idx];
                        if (h_mat == 0u) {
                            teleport = hop;
                            teleport_idx = h_idx;
                            break;
                        }
                        if (h_mat != material) {
                            blocked = true;
                            break;
                        }
                        if ((seed_in.data[h_idx] & SEED_SLEEP_BIT) != 0u) {
                            blocked = true;
                            break;
                        }
                    }
                    if (!blocked && teleport_idx != 0u) {
                        target = teleport;
                        t_idx = teleport_idx;
                        t_mat = 0u;
                        gain += 3.0;
                    }
                }
            }
        }

        if (is_water) {
            // Cohesion bias: prefer moves that keep water clustered.
            int target_like = 0;
            int target_air = 0;
            for (int j = 0; j < NEIGHBOR_COUNT; j++) {
                ivec3 nn = target + offsets[j];
                if (!in_bounds(nn) || !bcc_parity(nn)) {
                    continue;
                }
                uint nn_idx = atlas_index_for_cell(nn);
                if (nn_idx == 0u) {
                    continue;
                }
                uint nn_mat = atlas_in.data[nn_idx];
                if (nn_mat == WATER_MATERIAL) {
                    target_like++;
                } else if (nn_mat == 0u || nn_mat == OXYGEN_MATERIAL) {
                    target_air++;
                }
            }
            // Penalize moves that increase exposure; reward moves that increase contact with water.
            gain += float(target_like - like_count) * 1.6;
            gain -= float(target_air - air_count) * 1.2;
            // 4-hop fan-out lookahead: prefer open paths that trend downward.
            float hop_bonus = 0.0;
            ivec3 hop_cells[4];
            hop_cells[0] = target;
            hop_cells[1] = target + offset;
            hop_cells[2] = target + offset * 2;
            hop_cells[3] = target + offset * 3;
            for (int h = 0; h < 4; h++) {
                ivec3 hop = hop_cells[h];
                if (!in_bounds(hop) || !bcc_parity(hop)) {
                    continue;
                }
                uint h_idx = atlas_index_for_cell(hop);
                if (h_idx == 0u) {
                    continue;
                }
                if (atlas_in.data[h_idx] == 0u) {
                    hop_bonus += 0.35;
                }
            }
            // One-step fan around target (14-neighbor ring).
            for (int j = 0; j < NEIGHBOR_COUNT; j++) {
                ivec3 ring = target + offsets[j];
                if (!in_bounds(ring) || !bcc_parity(ring)) {
                    continue;
                }
                uint r_idx = atlas_index_for_cell(ring);
                if (r_idx == 0u) {
                    continue;
                }
                if (atlas_in.data[r_idx] == 0u) {
                    hop_bonus += 0.18;
                }
            }
            // If the chosen direction aligns with gravity, boost the lookahead value.
            hop_bonus += max(0.0, gravity_align[i]) * 0.45;
            gain += hop_bonus;
        }

        bool can_swap = false;
        float displacement_cost = 0.0;
        if (t_mat != 0u) {
            if (t_mat == material) {
                continue;
            }
            if ((seed_in.data[t_idx] & SEED_SLEEP_BIT) != 0u) {
                // Settled voxels are immovable until explicitly woken.
                continue;
            }
            uint t_index = t_mat * MATERIAL_PROPS_STRIDE;
            vec4 t_props0 = material_props.data[t_index + 0u];
            float t_resistance = t_props0.w;
            displacement_cost = t_resistance;
            if (wealth + gain > displacement_cost) {
                can_swap = true;
            } else {
                continue;
            }
        }

        float incentive = gain + wealth - move_cost - displacement_cost;
        if (incentive > best_incentive) {
            best_incentive = incentive;
            best_offset = offset;
            best_swap = can_swap;
            best_target_mat = t_mat;
            best_down = down;
        }
    }

    if (is_water && best_down <= 0.0 && max_lateral_dp < 1.0 && best_incentive < 1.0) {
        best_incentive = 0.0;
    }

    if (best_incentive > 0.0) {
        ivec3 target = cell + best_offset;
        uint t_idx = atlas_index_for_cell(target);
        if (t_idx != 0u) {
            if (best_swap && best_target_mat != 0u) {
                if (atomicCompSwap(atlas_out.data[t_idx], 0u, material) == 0u
                    && atomicCompSwap(atlas_out.data[self_idx], 0u, best_target_mat) == 0u) {
                    float new_wealth = max(0.0, wealth + best_incentive - resistance);
                    uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
                    seed_out.data[t_idx] = new_seed;
                    seed_out.data[self_idx] = 0u;
                    return;
                }
            } else if (!best_swap && best_target_mat == 0u) {
                if (atomicCompSwap(atlas_out.data[t_idx], 0u, material) == 0u) {
                    float down_gain = max(0.0, gravity_align[down_index]) * mass * 0.2;
                    float new_wealth = max(0.0, wealth + down_gain - drag);
                    uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
                    seed_out.data[t_idx] = new_seed;
                    return;
                }
            }
        }
    }

    if (atomicCompSwap(atlas_out.data[self_idx], 0u, material) == 0u) {
        float new_wealth = max(0.0, wealth - drag);
        uint new_seed = (seed & SEED_META_RANDOM_MASK) | (uint(clamp(new_wealth * 256.0, 0.0, 65535.0)));
        // Auto-sleep once we're supported and out of kinetic energy.
        if (supported && new_wealth <= 0.001) {
            new_seed |= SEED_SLEEP_BIT;
        }
        seed_out.data[self_idx] = new_seed;
    }
}
