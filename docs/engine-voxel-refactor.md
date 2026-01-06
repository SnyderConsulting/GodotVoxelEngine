# Engine Voxel Refactor Notes (Arbitrary Geometry)

Goal: refactor engine-src to support arbitrary voxel geometry, with truncated octahedron
as the primary target lattice.

## Relevant Parts And Hard Facts (Line References)

### VoxelGI And Voxelizer (scene/3d)
- Octree cell structure with 8 children and integer xyz coordinates.
  - godot/engine-src/scene/3d/voxelizer.h:50
  - godot/engine-src/scene/3d/voxelizer.h:51
  - godot/engine-src/scene/3d/voxelizer.h:56
  - godot/engine-src/scene/3d/voxelizer.h:57
  - godot/engine-src/scene/3d/voxelizer.h:58
- Power-of-two subdivisions and axis cell sizes are core to the voxelizer.
  - godot/engine-src/scene/3d/voxelizer.h:69
  - godot/engine-src/scene/3d/voxelizer.h:99
  - godot/engine-src/scene/3d/voxelizer.cpp:674
  - godot/engine-src/scene/3d/voxelizer.cpp:688
- Octree split uses AABB halving and 3-bit child indexing.
  - godot/engine-src/scene/3d/voxelizer.cpp:236
  - godot/engine-src/scene/3d/voxelizer.cpp:239
  - godot/engine-src/scene/3d/voxelizer.cpp:245
- Cell size is derived from a cubic power-of-two bound.
  - godot/engine-src/scene/3d/voxelizer.cpp:691
  - godot/engine-src/scene/3d/voxelizer.cpp:703
- Octree size is exposed as a Vector3i grid.
  - godot/engine-src/scene/3d/voxelizer.cpp:720
- Position packing uses bit shifts (xyz in a single uint32).
  - godot/engine-src/scene/3d/voxelizer.cpp:765
  - godot/engine-src/scene/3d/voxelizer.cpp:766
- Debug voxel mesh is generated as a cube (6 faces).
  - godot/engine-src/scene/3d/voxelizer.cpp:996
  - godot/engine-src/scene/3d/voxelizer.cpp:1018
- VoxelGI subdivision options are fixed to powers of two.
  - godot/engine-src/scene/3d/voxel_gi.h:101
  - godot/engine-src/scene/3d/voxel_gi.h:102
  - godot/engine-src/scene/3d/voxel_gi.h:103
  - godot/engine-src/scene/3d/voxel_gi.h:104
  - godot/engine-src/scene/3d/voxel_gi.h:105
- VoxelGI bake volume is an axis-aligned AABB derived from size.
  - godot/engine-src/scene/3d/voxel_gi.cpp:440
  - godot/engine-src/scene/3d/voxel_gi.cpp:505
- Estimated cell sizes use longest axis and power-of-two subdivisions.
  - godot/engine-src/scene/3d/voxel_gi.cpp:404
  - godot/engine-src/scene/3d/voxel_gi.cpp:409
  - godot/engine-src/scene/3d/voxel_gi.cpp:410
  - godot/engine-src/scene/3d/voxel_gi.cpp:427

### RenderingServer VoxelGI API
- VoxelGI allocation uses a Vector3i octree size and packed cell buffers.
  - godot/engine-src/servers/rendering/rendering_server.h:715
  - godot/engine-src/servers/rendering/rendering_server.h:718

### Renderer RD VoxelGI Shaders
- VoxelGI uses 3D textures for voxel data and SDF.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:71
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:100
- Cell data is packed into a uint32 position and decoded into xyz.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:26
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:27
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:33
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:347
- Cell size is computed as a uniform axis-aligned grid.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:172
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:418

### SDFGI Shaders
- SDFGI also relies on 3D voxel grids.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/gi.glsl:25
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/gi.glsl:53
- SDFGI derives sampling from a grid_size and to_cell scale.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/gi.glsl:38
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/gi.glsl:369

### GridMap (modules/gridmap)
- GridMap cells are defined as cube-map space cells.
  - godot/engine-src/modules/gridmap/grid_map.h:84
- GridMap defaults to cubic cell size and octant size 8.
  - godot/engine-src/modules/gridmap/grid_map.h:169
  - godot/engine-src/modules/gridmap/grid_map.h:170
- Octant keys are computed by integer division of xyz by octant_size.
  - godot/engine-src/modules/gridmap/grid_map.cpp:531
  - godot/engine-src/modules/gridmap/grid_map.cpp:544
- Map/local transforms are per-axis scaling on cell_size.
  - godot/engine-src/modules/gridmap/grid_map.cpp:557
  - godot/engine-src/modules/gridmap/grid_map.cpp:564
- GridMap rotation is restricted to 24 orthogonal bases.
  - godot/engine-src/modules/gridmap/grid_map.cpp:461
  - godot/engine-src/modules/gridmap/grid_map.cpp:685
- GridMap instance transforms are cellpos * cell_size (axis-aligned).
  - godot/engine-src/modules/gridmap/grid_map.cpp:686

### Mesh Convex Decomposition (scene/resources)
- Convex decomposition defaults to a voxel mode and exposes voxel resolution.
  - godot/engine-src/scene/resources/mesh.h:218
  - godot/engine-src/scene/resources/mesh.h:223
  - godot/engine-src/scene/resources/mesh.h:232
  - godot/engine-src/scene/resources/mesh.h:233

## Noteworthy From The Scan
- The VoxelGI shader comment says "xyz 10 bits" for CellData.position, but the CPU packing
  in Voxelizer uses x in 11 bits (0x7FF) and y in 10 bits (0x3FF), with z in the remaining
  bits. This is a documentation mismatch worth correcting if we touch the packing format.
  - godot/engine-src/servers/rendering/renderer_rd/shaders/environment/voxel_gi.glsl:27
  - godot/engine-src/scene/3d/voxelizer.cpp:765
  - godot/engine-src/scene/3d/voxelizer.cpp:766
- VoxelGI debug drawing is cube-based, so any new lattice needs a new debug mesh path.
  - godot/engine-src/scene/3d/voxelizer.cpp:996
  - godot/engine-src/scene/3d/voxelizer.cpp:1018
