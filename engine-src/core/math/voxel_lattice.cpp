#include "voxel_lattice.h"

static void _init_neighbor_offsets(Vector<Vector3i> &r_offsets, VoxelLattice::Type p_type) {
	if (!r_offsets.is_empty()) {
		return;
	}

	if (p_type == VoxelLattice::TYPE_TRUNCATED_OCTAHEDRON) {
		r_offsets.push_back(Vector3i(2, 0, 0));
		r_offsets.push_back(Vector3i(-2, 0, 0));
		r_offsets.push_back(Vector3i(0, 2, 0));
		r_offsets.push_back(Vector3i(0, -2, 0));
		r_offsets.push_back(Vector3i(0, 0, 2));
		r_offsets.push_back(Vector3i(0, 0, -2));
		r_offsets.push_back(Vector3i(1, 1, 1));
		r_offsets.push_back(Vector3i(1, 1, -1));
		r_offsets.push_back(Vector3i(1, -1, 1));
		r_offsets.push_back(Vector3i(1, -1, -1));
		r_offsets.push_back(Vector3i(-1, 1, 1));
		r_offsets.push_back(Vector3i(-1, 1, -1));
		r_offsets.push_back(Vector3i(-1, -1, 1));
		r_offsets.push_back(Vector3i(-1, -1, -1));
	} else {
		r_offsets.push_back(Vector3i(1, 0, 0));
		r_offsets.push_back(Vector3i(-1, 0, 0));
		r_offsets.push_back(Vector3i(0, 1, 0));
		r_offsets.push_back(Vector3i(0, -1, 0));
		r_offsets.push_back(Vector3i(0, 0, 1));
		r_offsets.push_back(Vector3i(0, 0, -1));
	}
}

bool VoxelLattice::is_valid_cell(Type p_type, const Vector3i &p_cell) {
	if (p_type == TYPE_TRUNCATED_OCTAHEDRON) {
		const int px = p_cell.x & 1;
		const int py = p_cell.y & 1;
		const int pz = p_cell.z & 1;
		return (px == py) && (py == pz);
	}

	return true;
}

Vector3i VoxelLattice::nearest_cell(Type p_type, const Vector3 &p_position) {
	if (p_type != TYPE_TRUNCATED_OCTAHEDRON) {
		return Vector3i(p_position.floor());
	}

	Vector3 base = p_position.floor();
	Vector3i base_i = Vector3i(base);
	Vector3i best = base_i;
	float best_dist_sq = 1e30f;

	for (int dz = 0; dz <= 1; dz++) {
		for (int dy = 0; dy <= 1; dy++) {
			for (int dx = 0; dx <= 1; dx++) {
				Vector3i cand = base_i + Vector3i(dx, dy, dz);
				if (!is_valid_cell(TYPE_TRUNCATED_OCTAHEDRON, cand)) {
					continue;
				}
				Vector3 delta = p_position - Vector3(cand);
				float dist_sq = delta.length_squared();
				if (dist_sq < best_dist_sq) {
					best_dist_sq = dist_sq;
					best = cand;
				}
			}
		}
	}

	return best;
}

const Vector<Vector3i> &VoxelLattice::get_neighbor_offsets(Type p_type) {
	static Vector<Vector3i> offsets_cubic;
	static Vector<Vector3i> offsets_truncated_octahedron;

	if (p_type == TYPE_TRUNCATED_OCTAHEDRON) {
		_init_neighbor_offsets(offsets_truncated_octahedron, TYPE_TRUNCATED_OCTAHEDRON);
		return offsets_truncated_octahedron;
	}

	_init_neighbor_offsets(offsets_cubic, TYPE_CUBIC);
	return offsets_cubic;
}

int VoxelLattice::get_neighbor_count(Type p_type) {
	return get_neighbor_offsets(p_type).size();
}
