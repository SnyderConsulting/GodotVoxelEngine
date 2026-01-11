# Prototype Requirements: Hourglass Test

Purpose: flowing sand through a neck to validate sim, lighting, and glass outline rendering under gravity changes.

Scene makeup:
- Geometry: glass hourglass shell (material id 8 outline) with two bulbs and a narrow neck; wall thickness ~2 voxels, shell padding ~0.45 for visible outline.
- Bulb sizing: upper/lower bulb radius ~0.45 of grid extent; neck radius ~0.12 of grid extent to restrict flow.
- Fill: sand material id 1 in the upper bulb only; sand density ~0.85 (probabilistic fill). Glass is immobile; sand moves.
- Grid: BCC lattice; chunk_size/chunk_grid large enough for the hourglass silhouette (current demo uses chunk_size 8, chunk_grid 20).
- Gravity/world rotation: sliders; Esc returns to hub; gravity defaults to downward (0, -1, 0).
- Overlay: scene name, brief usage hint; gravity/world values optional.
- RNG: seeded (e.g., 4242) for repeatable fill layout.
