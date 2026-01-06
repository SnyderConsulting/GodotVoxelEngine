# Engine Voxel Audit (Godot)

## Summary
- VoxelGI, SDFGI, and GridMap are built on axis-aligned cubic grids.
- VoxelGI uses an octree with 8-way child splits and power-of-two subdivisions.
- GridMap uses cubic cells with 24 orthogonal rotations and cubic octants.
- The RenderingServer API exposes voxel GI data as a Vector3i grid plus packed xyz coords.
- There is no shared abstraction for non-cubic voxel lattices in engine-src today.

## Implications For VoxLand
- Supporting arbitrary voxel geometry (especially truncated octahedron) requires new lattice
  math, adjacency, storage layouts, and sampling paths inside the engine.
- VoxelGI, SDFGI, and GridMap will need either major refactors or parallel systems that are
  lattice-aware.

## Subsystems Touched
- scene/3d: voxel_gi.*, voxelizer.*
- servers/rendering: rendering_server.h, VoxelGI and SDFGI shaders
- modules/gridmap: grid_map.*
- scene/resources: mesh.h (convex decomposition voxel mode)
