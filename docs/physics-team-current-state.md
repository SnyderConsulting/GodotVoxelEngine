# VoxLand Current Technical Implementation (Godot)

This document summarizes the *current* in-engine technical setup of VoxLand for the physics research team. It describes what is implemented today in Godot without requiring access to the project source.

## 1) Core Pipeline Overview

The system is a GPU-driven voxel simulation and renderer. The simulation, lighting, and raymarching all run on the GPU via compute shaders. Each frame:

1) Simulation step (optional; enabled in our test scenes) updates voxel occupancy for sand.
2) A flood-fill light pass propagates light through empty space.
3) A raymarch pass renders the voxel volume using a signed-distance field (SDF) of the voxel shape.

The CPU side primarily sets up buffers, uploads the voxel grid, and pushes per-frame parameters such as camera, gravity, and world rotation.

## 2) Voxel Lattice + Shape

**Lattice**  
We use a **body-centered cubic (BCC) lattice**. Only grid cells where `(x & 1) == (y & 1) == (z & 1)` are considered valid voxel positions. This creates the two interleaved sub-lattices characteristic of BCC and reduces aliasing for the non-cube voxel shape.

**Voxel shape**  
Each voxel is rendered as a **truncated octahedron**, implemented as an SDF. Rendering uses sphere tracing (small steps inside the voxel’s bounding region) to intersect the truncated octahedron. Normals are computed by finite-differencing the SDF.

Why this matters:
- The truncated octahedron fits well in a BCC lattice and allows more isotropic movement than cubes.
- The SDF is the single source of truth for appearance and hit tests.

## 3) Grid + Brickmap Data Layout

The voxel volume is stored in a **brickmap**:
- **brick_size**: number of cells per brick (default in scenes is 8).
- **chunk_grid**: number of bricks per axis (scene-dependent).
- **grid_extent** = `brick_size * chunk_grid`.

The brickmap consists of:
- **Indirection buffer**: maps brick index -> brick data index; zero means “brick absent.”
- **Atlas buffers**: two full voxel grids (double-buffered) storing per-cell material IDs.
- **Occupancy buffer**: per-brick flag indicating whether any non-empty voxels exist.
- **Active list + indirect dispatch**: GPU-generated list of occupied bricks and dispatch arguments for the simulation pass, allowing the sim to update only active bricks.

## 4) Materials + Shading

Per-voxel material IDs are stored in the atlas (uint). Current IDs:
- **0**: empty
- **1**: sand (default)
- **8**: glass (special case)

Rendering uses a small palette (8 colors) indexed by `(material_id - 1) % 8`. Sand uses the first palette entry (a tan/brown tone). Lighting is applied with a mix of ambient, diffuse, soft-shadowing, and a small specular term.

**Glass** is not rendered as a solid; it is an **outline**. When raymarching, glass voxels produce a thin edge highlight around the truncated octahedron surface instead of opaque shading, so sand remains visible through glass containers.

## 5) Lighting

Lighting is a simple GPU flood-fill:
- Light source: empty cells on the **top layer** of the grid emit max light.
- Light propagates through empty space in 14 BCC-adjacent directions.
- Glass is treated as **non-solid** for lighting (it does not block light).
- Light levels decay by 1 per step (max 15).

The final shading mixes this light value into ambient + diffuse terms.

## 6) Simulation / Movement Rules

Current movement is **cellular, per-voxel, GPU-based**, not rigid-body physics.

Key rules:
- **Only non-glass voxels move.** Glass is fixed.
- Each voxel checks 14 BCC neighbors (6 axial at distance 2 + 8 diagonals at distance 1).
- Neighbors are scored by `dot(offset, gravity_dir)` and the top 4 candidates are kept.
- A hash-based tie-breaker selects among candidates to reduce bias.
- Movement uses atomic compare-and-swap to claim a target cell; otherwise the voxel stays.
- No velocity, no inertia, and no multi-step collision response — this is a discrete “falling sand” model.

**Gravity vs world rotation**  
Gravity is defined independently of world rotation. The world rotation only rotates the rendered volume; gravity is transformed by the inverse world rotation before it is used in the simulation. This lets you rotate the world without changing the direction of gravity, or rotate gravity without rotating the world.

## 7) Raymarching and Brick-Skip DDA

Rendering uses a brick-aware raymarch:
- The ray advances in brick-sized steps when in empty regions.
- If a brick is empty, neighbor bricks are checked before skipping to avoid missing close voxels.
- Inside an active brick, the ray marches using the SDF and a “nearest BCC cell” lookup.

This provides the **brick-skip DDA** behavior for performance.

## 8) Test Scenes (Current)

### A) Tumbler Test
Purpose: baseline sand container with gravity/world controls.
- Glass container: full cube shell.
- Sand fill: random fill up to ~55% height.
- Density: ~0.75.
- Grid: `brick_size=8`, `chunk_grid=3` (24^3 cells).

### B) Hourglass Test
Purpose: glass hourglass with flowing sand.
- Glass hourglass shape (two bulbs + neck).
- Sand in the upper bulb only.
- Bulb radius ratio: 0.45 of grid size.
- Neck radius ratio: 0.12.
- Wall thickness: 2.
- Shell padding: 0.45 (visual thickness/outline control).
- Density: ~0.85.
- Grid: `brick_size=8`, `chunk_grid=20` (160^3 cells).

### C) Glass + Sand Template
Purpose: template scene showing glass + sand containers on a surface.
- Glass table surface with a rim (prevents sand escape).
- Glass bowl: open hemisphere.
- Glass cup: open cylinder.
- Sand inside bowl and cup.
- Bowl radius ratio: 0.24.
- Cup radius ratio: 0.10 (reduced for proportion balance).
- Cup height ratio: 0.38.
- Density: ~0.85.
- Grid: `brick_size=8`, `chunk_grid=16` (128^3 cells).

## 9) Controls + Camera

**Orbit camera**
- Left-drag: orbit.
- Shift+left-drag: pan.
- Mouse wheel: zoom (clamped by per-scene min/max distance).

**Gravity + world rotation UI**
- UI panel provides sliders for gravity yaw/pitch and world yaw/pitch/roll.
- Gravity and world rotation are independent (as described above).
- A reset button returns both to zeroed defaults.

## 10) What This Means for a Physics Team

Right now the simulation is intentionally simple:
- It is discrete, per-voxel, and gravity-driven.
- There is no impulse-based contact solver, velocity accumulation, or collision response beyond “try to move into an empty neighbor.”
- Glass voxels are static geometry with visual-only translucency.

If the research team is building a deeper physics system, the current Godot implementation is best viewed as:
- A GPU voxel renderer + visualization sandbox.
- A deterministic, cellular sand movement baseline.
- A known lattice + voxel shape (truncated octahedron on BCC).

If you need numeric datasets (voxel counts for each scene, distribution statistics, etc.), I can generate those on request. Alternatively, I can produce a structured spec (JSON/CSV) with all scene parameters for integration or benchmarking. 
