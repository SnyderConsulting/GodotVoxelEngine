#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer ActiveCount {
	uint count;
} active_count;

layout(set = 0, binding = 1, std430) buffer IndirectArgs {
	uvec3 args;
} indirect_args;

void main() {
	indirect_args.args = uvec3(active_count.count, 1u, 1u);
}
