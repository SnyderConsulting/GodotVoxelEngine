#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) readonly buffer Indirection {
	uint data[];
} indirection;

layout(set = 0, binding = 1, std430) buffer InAtlas {
	uint data[];
} in_atlas;

layout(set = 0, binding = 2, std430) buffer OutAtlas {
	uint data[];
} out_atlas;

layout(set = 0, binding = 3, std430) buffer Params {
	uvec4 grid;   // xyz = grid size, w = step id
	uvec4 brick;  // xyz = brick dims, w = brick size
	vec4 vacuum;
} params;

layout(set = 0, binding = 4, std430) buffer Counts {
	uint moved;
	uint deleted;
} counts;

layout(set = 0, binding = 5, std430) readonly buffer ActiveList {
	uint data[];
} active_list;

const uint MAT_EMPTY = 0u;
const uint MAT_SAND = 1u;
const uint MAT_WALL = 2u;
const uint MAT_MASK = 3u;
const uint ACTIVE_MASK = 4u;
const uint VACUUM_MASK = 8u;
const uint VACUUM_MOVED = 16u;

bool in_bounds(int x, int y, int z) {
	return x >= 0 && y >= 0 && z >= 0 && x < int(params.grid.x) && y < int(params.grid.y) && z < int(params.grid.z);
}

int brick_linear(ivec3 b) {
	return (b.z * int(params.brick.y) + b.y) * int(params.brick.x) + b.x;
}

int brick_index_for(int x, int y, int z) {
	if (!in_bounds(x, y, z)) {
		return -1;
	}
	int brick_size = int(params.brick.w);
	ivec3 b = ivec3(x / brick_size, y / brick_size, z / brick_size);
	int bindex = brick_linear(b);
	uint ind = indirection.data[bindex];
	if (ind == 0u) {
		return -1;
	}
	return int(ind - 1u);
}

uint atlas_index(int x, int y, int z) {
	int bindex = brick_index_for(x, y, z);
	if (bindex < 0) {
		return 0u;
	}
	int brick_size = int(params.brick.w);
	int lx = x % brick_size;
	int ly = y % brick_size;
	int lz = z % brick_size;
	int local_index = (lz * brick_size + ly) * brick_size + lx;
	return uint(bindex * (brick_size * brick_size * brick_size) + local_index);
}

uint get_cell(int x, int y, int z) {
	if (!in_bounds(x, y, z)) {
		return MAT_WALL;
	}
	return in_atlas.data[atlas_index(x, y, z)];
}

uint hash_u(uint x, uint y, uint z, uint frame) {
	uint h = x * 374761393u + y * 668265263u + z * 2246822519u + frame * 3266489917u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	return h ^ (h >> 16u);
}

bool active_for(int x, int y, int z, uint cell) {
	if ((cell & MAT_MASK) != MAT_SAND) {
		return false;
	}
	if ((cell & VACUUM_MASK) != 0u) {
		return true;
	}
	if ((cell & ACTIVE_MASK) != 0u) {
		return true;
	}
	uint below = get_cell(x, y - 1, z);
	return (below & MAT_MASK) == MAT_EMPTY;
}

ivec3 vacuum_dir(int x, int y, int z) {
	vec3 aim = params.vacuum.xyz;
	vec3 pos = vec3(float(x) + 0.5, float(y) + 0.5, float(z) + 0.5);
	vec3 dir = aim - pos;
	vec3 adir = abs(dir);
	ivec3 primary = ivec3(0);
	ivec3 secondary = ivec3(0);
	ivec3 tertiary = ivec3(0);

	if (adir.x >= adir.y && adir.x >= adir.z) {
		primary = ivec3(dir.x >= 0.0 ? 1 : -1, 0, 0);
		secondary = ivec3(0, dir.y >= 0.0 ? 1 : -1, 0);
		tertiary = ivec3(0, 0, dir.z >= 0.0 ? 1 : -1);
	} else if (adir.y >= adir.z) {
		primary = ivec3(0, dir.y >= 0.0 ? 1 : -1, 0);
		secondary = ivec3(dir.x >= 0.0 ? 1 : -1, 0, 0);
		tertiary = ivec3(0, 0, dir.z >= 0.0 ? 1 : -1);
	} else {
		primary = ivec3(0, 0, dir.z >= 0.0 ? 1 : -1);
		secondary = ivec3(dir.x >= 0.0 ? 1 : -1, 0, 0);
		tertiary = ivec3(0, dir.y >= 0.0 ? 1 : -1, 0);
	}

	ivec3 step = primary;
	if ((get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY) {
		return step;
	}

	step = secondary;
	if ((get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY) {
		return step;
	}

	step = tertiary;
	if ((get_cell(x + step.x, y + step.y, z + step.z) & MAT_MASK) == MAT_EMPTY) {
		return step;
	}

	return ivec3(0);
}

ivec3 move_dir(int x, int y, int z, uint cell) {
	if ((cell & MAT_MASK) != MAT_SAND) {
		return ivec3(0);
	}
	if (!active_for(x, y, z, cell)) {
		return ivec3(0);
	}
	if ((cell & VACUUM_MASK) != 0u) {
		return vacuum_dir(x, y, z);
	}
	uint below = get_cell(x, y - 1, z);
	if ((below & MAT_MASK) == MAT_EMPTY) {
		return ivec3(0, -1, 0);
	}

	int r = int(hash_u(uint(x), uint(y), uint(z), params.grid.x + params.grid.y + params.grid.z + params.grid.w) & 3u);
	int dx[4] = int[4](-1, 1, 0, 0);
	int dz[4] = int[4](0, 0, -1, 1);
	for (int i = 0; i < 4; i++) {
		int k = (i + r) & 3;
		int nx = x + dx[k];
		int nz = z + dz[k];
		uint diag = get_cell(nx, y - 1, nz);
		if ((diag & MAT_MASK) == MAT_EMPTY) {
			return ivec3(dx[k], -1, dz[k]);
		}
	}

	return ivec3(0);
}

bool wants_move(int src_x, int src_y, int src_z, ivec3 dir) {
	if (!in_bounds(src_x, src_y, src_z)) {
		return false;
	}
	uint cell = get_cell(src_x, src_y, src_z);
	if ((cell & MAT_MASK) != MAT_SAND) {
		return false;
	}
	ivec3 desire = move_dir(src_x, src_y, src_z, cell);
	return all(equal(desire, dir));
}

bool is_vacuumed(int src_x, int src_y, int src_z) {
	if (!in_bounds(src_x, src_y, src_z)) {
		return false;
	}
	uint cell = get_cell(src_x, src_y, src_z);
	return (cell & VACUUM_MASK) != 0u;
}

void main() {
	uint list_index = gl_WorkGroupID.x;
	uint brick_linear_index = active_list.data[list_index];
	uint bx = brick_linear_index % params.brick.x;
	uint by = (brick_linear_index / params.brick.x) % params.brick.y;
	uint bz = brick_linear_index / (params.brick.x * params.brick.y);

	int brick_size = int(params.brick.w);
	ivec3 local = ivec3(gl_LocalInvocationID.xyz);
	int x = int(bx) * brick_size + local.x;
	int y = int(by) * brick_size + local.y;
	int z = int(bz) * brick_size + local.z;
	if (!in_bounds(x, y, z)) {
		return;
	}

	uint index = atlas_index(x, y, z);
	uint cell = get_cell(x, y, z);
	uint mat = cell & MAT_MASK;

	if (mat == MAT_WALL) {
		out_atlas.data[index] = MAT_WALL;
		return;
	}

	if (mat == MAT_SAND && (cell & VACUUM_MASK) != 0u) {
		vec3 pos = vec3(float(x) + 0.5, float(y) + 0.5, float(z) + 0.5);
		float dist = distance(pos, params.vacuum.xyz);
		if (dist <= params.vacuum.w * 1.5) {
			out_atlas.data[index] = MAT_EMPTY;
			atomicAdd(counts.deleted, 1u);
			return;
		}
	}

	uint incoming_count = 0u;
	bool incoming = false;
	bool incoming_vacuum = false;
	uint seed = hash_u(uint(x), uint(y), uint(z), params.grid.w);

	if (wants_move(x, y + 1, z, ivec3(0, -1, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y + 1, z);
		}
	}

	if (wants_move(x, y - 1, z, ivec3(0, 1, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y - 1, z);
		}
	}

	if (wants_move(x - 1, y, z, ivec3(1, 0, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x - 1, y, z);
		}
	}

	if (wants_move(x + 1, y, z, ivec3(-1, 0, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x + 1, y, z);
		}
	}

	if (wants_move(x, y, z - 1, ivec3(0, 0, 1))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y, z - 1);
		}
	}

	if (wants_move(x, y, z + 1, ivec3(0, 0, -1))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y, z + 1);
		}
	}

	if (wants_move(x - 1, y + 1, z, ivec3(1, -1, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x - 1, y + 1, z);
		}
	}

	if (wants_move(x + 1, y + 1, z, ivec3(-1, -1, 0))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x + 1, y + 1, z);
		}
	}

	if (wants_move(x, y + 1, z - 1, ivec3(0, -1, 1))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y + 1, z - 1);
		}
	}

	if (wants_move(x, y + 1, z + 1, ivec3(0, -1, -1))) {
		incoming_count += 1u;
		if ((seed % incoming_count) == 0u) {
			incoming = true;
			incoming_vacuum = is_vacuumed(x, y + 1, z + 1);
		}
	}

	if (incoming) {
		if (incoming_vacuum && mat == MAT_EMPTY) {
			out_atlas.data[index] = MAT_SAND | ACTIVE_MASK | VACUUM_MASK | VACUUM_MOVED;
			atomicAdd(counts.moved, 1u);
			return;
		}
		if (mat == MAT_EMPTY) {
			out_atlas.data[index] = MAT_SAND | ACTIVE_MASK;
			return;
		}
	}

	if (mat == MAT_SAND) {
		ivec3 dir = move_dir(x, y, z, cell);
		if (all(equal(dir, ivec3(0)))) {
			bool is_active = active_for(x, y, z, cell);
			uint keep_vacuum = cell & VACUUM_MASK;
			uint moved_flag = cell & VACUUM_MOVED;
			out_atlas.data[index] = MAT_SAND | (is_active ? ACTIVE_MASK : 0u) | keep_vacuum | moved_flag;
			return;
		}
		out_atlas.data[index] = MAT_EMPTY;
		return;
	}

	out_atlas.data[index] = MAT_EMPTY;
}
