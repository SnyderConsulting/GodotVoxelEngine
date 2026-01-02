#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer Indirection {
	uint data[];
} indirection;

layout(set = 0, binding = 1, std430) readonly buffer Atlas {
	uint data[];
} atlas;

layout(set = 0, binding = 2, std430) buffer Params {
	vec4 grid_info;   // xyz = size, w = unused
	vec4 origin;      // xyz = grid origin in world space
	vec4 cam_pos;
	vec4 cam_right;
	vec4 cam_up;
	vec4 cam_forward;
	vec4 screen;      // xy = screen size, z = tan_half_fov, w = aspect
	vec4 misc;        // x = voxel_size, y = max_dist
	vec4 brick_info;  // xyz = brick dims, w = brick size
} params;

layout(set = 0, binding = 3, rgba8) uniform writeonly image2D out_image;
layout(set = 0, binding = 4, std430) readonly buffer Occupancy {
	uint data[];
} occ;

uint idx_brick(ivec3 b) {
	return uint(b.x) + uint(b.y) * uint(params.brick_info.x)
		+ uint(b.z) * uint(params.brick_info.x) * uint(params.brick_info.y);
}

bool in_bounds(ivec3 p) {
	return p.x >= 0 && p.y >= 0 && p.z >= 0
		&& p.x < int(params.grid_info.x)
		&& p.y < int(params.grid_info.y)
		&& p.z < int(params.grid_info.z);
}

uint atlas_index_for_cell(ivec3 cell) {
	int brick_size = int(params.brick_info.w);
	ivec3 brick = cell / brick_size;
	uint ind = indirection.data[idx_brick(brick)];
	if (ind == 0u) {
		return 0u;
	}
	uint brick_index = ind - 1u;
	ivec3 local = cell - brick * brick_size;
	uint local_index = uint(local.x) + uint(local.y) * uint(brick_size) + uint(local.z) * uint(brick_size * brick_size);
	return brick_index * uint(brick_size * brick_size * brick_size) + local_index;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(params.screen.x) || pixel.y >= int(params.screen.y)) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.screen.xy;
	vec2 ndc = uv * 2.0 - 1.0;

	vec3 dir = normalize(
		params.cam_forward.xyz
		+ params.cam_right.xyz * (ndc.x * params.screen.w * params.screen.z)
		+ params.cam_up.xyz * (ndc.y * params.screen.z)
	);

	float t = 0.0;
	float max_dist = params.misc.y;
	float step = max(params.misc.x * 0.5, 0.05);
	vec4 color = vec4(0.6, 0.7, 0.9, 1.0);
	int brick_size = int(params.brick_info.w);

	while (t <= max_dist) {
		vec3 pos = params.cam_pos.xyz + dir * t;
		vec3 local = (pos - params.origin.xyz) / params.misc.x;
		ivec3 cell = ivec3(floor(local));
		if (in_bounds(cell)) {
			ivec3 brick = cell / brick_size;
			uint occ_val = occ.data[idx_brick(brick)];
			if (occ_val == 0u) {
				vec3 brick_min = vec3(brick * brick_size);
				vec3 brick_max = brick_min + vec3(brick_size);
				vec3 dist;
				dist.x = (dir.x > 0.0) ? (brick_max.x - local.x) / dir.x
					: (dir.x < 0.0) ? (local.x - brick_min.x) / -dir.x : 1e9;
				dist.y = (dir.y > 0.0) ? (brick_max.y - local.y) / dir.y
					: (dir.y < 0.0) ? (local.y - brick_min.y) / -dir.y : 1e9;
dist.z = (dir.z > 0.0) ? (brick_max.z - local.z) / dir.z
					: (dir.z < 0.0) ? (local.z - brick_min.z) / -dir.z : 1e9;
				float t_next = min(dist.x, min(dist.y, dist.z)) * params.misc.x;
				t += max(t_next + 0.0001, step);
				continue;
			}
			uint cell_val = atlas.data[atlas_index_for_cell(cell)];
			if ((cell_val & 3u) != 0u) {
				color = vec4(0.90, 0.82, 0.62, 1.0);
				break;
			}
		}
		t += step;
	}

	imageStore(out_image, pixel, color);
}
