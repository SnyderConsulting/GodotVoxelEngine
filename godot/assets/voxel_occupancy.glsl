#[compute]
#version 450
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) readonly buffer Atlas {
	uint data[];
} atlas;

layout(set = 0, binding = 1, std430) buffer Occupancy {
	uint data[];
} occ;

layout(set = 0, binding = 2, std430) buffer Params {
	uvec4 grid_size;   // xyz = grid size
	uvec4 brick_info;  // xyz = brick dims, w = brick size
} params;

uint brick_idx(uvec3 b) {
	return b.x + b.y * params.brick_info.x + b.z * params.brick_info.x * params.brick_info.y;
}

void main() {
	uvec3 bid = gl_GlobalInvocationID.xyz;
	if (bid.x >= params.brick_info.x || bid.y >= params.brick_info.y || bid.z >= params.brick_info.z) {
		return;
	}

	uint brick_size = params.brick_info.w;
	uint brick_volume = brick_size * brick_size * brick_size;
	uint base_index = brick_idx(bid) * brick_volume;
	uint occupied = 0u;

	for (uint z = 0u; z < brick_size && occupied == 0u; z++) {
		for (uint y = 0u; y < brick_size && occupied == 0u; y++) {
			for (uint x = 0u; x < brick_size; x++) {
				uint gx = bid.x * brick_size + x;
				uint gy = bid.y * brick_size + y;
				uint gz = bid.z * brick_size + z;
				if (gx >= params.grid_size.x || gy >= params.grid_size.y || gz >= params.grid_size.z) {
					continue;
				}
				uint local_index = (z * brick_size + y) * brick_size + x;
				if ((atlas.data[base_index + local_index] & 3u) != 0u) {
					occupied = 1u;
					break;
				}
			}
		}
	}

	occ.data[brick_idx(bid)] = occupied;
}
