# Icosahedral Voxel Lattice Spec (Draft)

## Goal
Define a lattice where each voxel uses 12-neighbor adjacency (icosahedron-style) and can be rendered as an icosahedron primitive.

## Lattice Choice
Use a **face-centered cubic (FCC)** lattice for voxel centers:
- Each point has **12 equidistant neighbors**, matching icosahedral adjacency.
- This provides a practical, space-filling coordinate system with simple indexing.

## Coordinates
Represent lattice points with integer coordinates `(x, y, z)` where:
- `x + y + z` is **even** (FCC constraint).
- World position is `pos = vec3(x, y, z) * spacing`.

## Neighbor Offsets (12)
All permutations of:
```
(±1, ±1, 0)
(±1, 0, ±1)
(0, ±1, ±1)
```
These preserve `x + y + z` parity.

## Chunking (Brick Replacement)
Replace cubic bricks with **FCC chunks**:
- Chunk coordinates are still integer `(cx, cy, cz)` with the same parity rule.
- Each chunk stores a local FCC lattice subregion, e.g. `chunk_size = 8` (only positions with even parity are valid).
- The total voxel capacity is defined by chunk count, not a fixed 128^3 grid.

## Storage Layout (Concept)
- **Indirection buffer**: maps chunk coords → atlas index.
- **Atlas buffer**: stores occupancy/material data for FCC points in each chunk.
- **Occupancy**: per-chunk bitmask of active lattice points (only parity-valid points).

## Rendering Notes
- Raymarch queries convert world → FCC coords, then snap to nearest lattice point.
- Neighbor traversal uses the 12 offsets above.
- Visual primitive can be an icosahedron SDF per voxel, but occupancy is defined on FCC points.

## Open Items
- Final chunk size and packing format (bit density vs. material payload).
- SDF for icosahedron and per-voxel shading rules.
