# Truncated Octahedron Lattice Decision

## Summary
- We are switching from icosahedron voxels to truncated octahedra because they tessellate.
- The 8x8x8 brick size and 128^3 grid in the README/deep dive were placeholders.

## Affected Architecture Pieces
- **Brickmap layout**: The current cubic indexing becomes BCC-aware.
- **Grid resolution**: Capacity is defined by BCC lattice indexing, not a fixed 128^3.
- **Occupancy + traversal**: Parity rules change to BCC (all even or all odd).
- **GPU buffers**: Indirection, atlas, and occupancy encode BCC positions.

## Plan for Adaptation
- Define a truncated octahedron SDF based on `(0, 1, 2)` vertex ratios.
- Update raymarch traversal to respect BCC parity.
- Update documentation to reflect the new lattice and buffer formats.
