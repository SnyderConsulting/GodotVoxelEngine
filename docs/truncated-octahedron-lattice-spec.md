# Truncated Octahedron Voxel Lattice Spec (Draft)

## Goal
Define a lattice where each voxel is a truncated octahedron (Kelvin cell) and tessellates without gaps.

## Lattice Choice
Use a **body-centered cubic (BCC)** lattice for voxel centers:
- Valid cell centers are only where `x`, `y`, and `z` are all even or all odd.
- This forms the offset pattern needed for truncated octahedra to pack.

## Coordinates
Represent lattice points with integer coordinates `(x, y, z)` where:
- `(x & 1) == (y & 1) == (z & 1)` (all even or all odd).
- World position is `pos = vec3(x, y, z) * spacing`.

## Shape Geometry
Truncated Octahedron:
- Faces: 14 (6 squares, 8 hexagons)
- Edges: 36 (equal length)
- Vertices: 24
- Vertex coordinates: all permutations of `(0, 1, 2)` with sign flips, centered at `(0, 0, 0)` and scaled by size.

## Neighbor Count (14)
Each cell touches 14 neighbors:
- 6 via square faces
- 8 via hexagonal faces

## Chunking (Brick Replacement)
Replace cubic bricks with **BCC chunks**:
- Chunk coordinates are integer `(cx, cy, cz)` with the same parity rule.
- Each chunk stores local BCC lattice positions, e.g. `chunk_size = 8`.
- Capacity is defined by chunk count, not a fixed 128^3 grid.

## Storage Layout (Concept)
- **Indirection buffer**: maps chunk coords -> atlas index.
- **Atlas buffer**: stores occupancy/material data for BCC points in each chunk.
- **Occupancy**: per-chunk bitmask of active lattice points.

## Rendering Notes
- Raymarch queries convert world -> BCC coords and step cell-by-cell.
- Per-voxel shape uses a truncated octahedron SDF.
- Visual primitive is derived from the vertex ratio `(0, 1, 2)`.
