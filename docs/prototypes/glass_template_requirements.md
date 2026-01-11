# Prototype Requirements: Glass Surface + Bowl + Cup

Purpose: template scene showing multiple glass containers and sand piles on a surface to test simultaneous geometry, lighting, and UI controls.

Scene makeup:
- Surface: glass table/floor (material id 8 outline) with thickness ~2 voxels, edge padding ~8 voxels, and a low rim height ~3 voxels to keep sand in place.
- Bowl: open glass bowl/hemisphere with radius ~0.24 of grid extent; wall thickness ~2; sand clearance ~0.6; sand height ratio ~0.7 of inner depth.
- Cup: open glass cup/cylinder with radius ~0.10 of grid extent; height ~0.38 of grid extent; wall thickness ~2; sand height ratio ~0.7 of inner depth.
- Gap/placement: bowl and cup separated by a gap ratio ~0.08 of grid extent with a minimum gap of ~6 voxels; both sit on the surface.
- Fill: sand material id 1 inside bowl and cup with density ~0.85 (probabilistic fill). Glass remains immobile.
- Grid: BCC lattice; chunk_size/chunk_grid large enough to fit surface plus containers (current demo uses chunk_size 8, chunk_grid 16).
- Gravity/world rotation: sliders; Esc returns to hub.
- Overlay: scene title and optional gravity/world values.
- RNG: seeded (e.g., 2026) for repeatable fill layout.
