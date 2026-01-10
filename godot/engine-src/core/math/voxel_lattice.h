#pragma once

#include "core/math/vector3.h"
#include "core/math/vector3i.h"
#include "core/templates/vector.h"

class VoxelLattice {
public:
	enum Type {
		TYPE_CUBIC = 0,
		TYPE_TRUNCATED_OCTAHEDRON = 1,
		TYPE_MAX
	};

	static bool is_valid_cell(Type p_type, const Vector3i &p_cell);
	static Vector3i nearest_cell(Type p_type, const Vector3 &p_position);
	static const Vector<Vector3i> &get_neighbor_offsets(Type p_type);
	static int get_neighbor_count(Type p_type);
};
