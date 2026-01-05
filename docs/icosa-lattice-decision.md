# Icosahedral Voxel Lattice Decision

## Summary
- We are moving from a Cartesian voxel grid to an icosahedral lattice.
- The 8x8x8 brick size and 128^3 grid in the README/deep dive were placeholders and are no longer binding.

## Affected Architecture Pieces
- **Brickmap layout**: The current 8x8x8 brick + indirection mapping assumes cubic cells. This will be replaced with a lattice-aware addressing scheme.
- **Grid resolution**: 128^3 is removed. We will define capacity based on the icosahedral lattice indexing strategy.
- **Occupancy + traversal**: Neighbor rules and raymarch traversal must be rewritten for the new lattice.
- **GPU buffers**: Indirection, atlas, and occupancy buffers will change format to encode lattice coordinates and adjacency.

## Plan for Adaptation
- Define an icosahedral lattice coordinate system + indexing scheme.
- Redefine “brick” as a lattice tile/chunk for locality (size TBD).
- Update compute raymarch to query occupancy via the new indexing scheme.
- Adjust documentation to reflect the new lattice and buffer formats.
