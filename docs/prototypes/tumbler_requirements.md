# Prototype Requirements: Tumbler Test

Purpose: baseline voxel container demo to validate sand fill, glass outline, gravity/world rotation controls, and renderer stability.

Scene makeup:
- Container: glass cube shell with uniform wall thickness; uses glass material id 8 rendered as outline so sand remains visible.
- Fill: sand material id 1, random distribution up to ~55% of the container height with density ~0.75 (probabilistic fill).
- Grid: body-centered cubic (BCC) lattice; choose chunk_grid/chunk_size large enough to contain the cube and sand bed (current demo uses chunk_size 8, chunk_grid 3).
- Gravity/world rotation: sliders that independently rotate gravity vector and world orientation; Esc returns to hub.
- Overlay: minimal text with scene name and gravity/world rotation values.
- Determinism: seeded RNG (e.g., 1337) for repeatable fills.
