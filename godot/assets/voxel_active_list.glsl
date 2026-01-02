#[compute]
#version 450
layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) readonly buffer Occupancy {
	uint data[];
} occ;

layout(set = 0, binding = 1, std430) buffer ActiveList {
	uint data[];
} active_list;

layout(set = 0, binding = 2, std430) buffer ActiveCount {
	uint count;
} active_count;

layout(set = 0, binding = 3, std430) buffer Params {
	uvec4 grid_size;
	uvec4 brick_info; // xyz = brick dims, w = brick size
} params;

uint brick_idx(uvec3 b) {
	return b.x + b.y * params.brick_info.x + b.z * params.brick_info.x * params.brick_info.y;
}

void main() {
	uvec3 bid = gl_GlobalInvocationID.xyz;
	if (bid.x >= params.brick_info.x || bid.y >= params.brick_info.y || bid.z >= params.brick_info.z) {
		return;
	}
	uint index = brick_idx(bid);
	if (occ.data[index] == 0u) {
		return;
	}
	uint write_index = atomicAdd(active_count.count, 1u);
	active_list.data[write_index] = index;
}
