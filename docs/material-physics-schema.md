# Material Physics Schema

This document defines the canonical material fields used by the voxel simulation and how they map from reference projects (The Powder Toy and Sandboxels).

## 1) Canonical Fields (GPU)
Each material occupies **8 floats** in the GPU material buffer:

1. `density`
2. `friction`
3. `viscosity`
4. `cohesion`
5. `drag`
6. `rest_cost`
7. `lateral_cost`
8. `gravity_bias`

These values live in `godot/project/data/materials.json` and are uploaded into a storage buffer for the sim pass. The compute shader uses them to compute a **resistance cost** for each candidate move.

## 2) Movement Cost (least resistance)
For a candidate offset `o` and gravity direction `g`:

```
move_len = length(o)
down = dot(o, g)
base_cost = friction + viscosity + cohesion + drag * move_len
if down > 0:
  cost = base_cost - down * gravity_bias
else:
  cost = base_cost + lateral_cost
```

A voxel moves to the lowest-cost neighbor only if that cost is cheaper than `rest_cost + drag` (staying still).

## 3) Reference Mapping (High Level)
The reference engines expose similar concepts but with different field names and ranges. We normalize into the canonical fields above.

### A) Sandboxels
- `density` -> `density`
- `viscosity` -> `viscosity`
- `friction` -> `friction`
- `drag`/`airDrag` -> `drag`
- `behavior` -> maps to *movement constraints* (e.g., WALL = immobile)

### B) The Powder Toy
- `Weight` -> `density` (normalized)
- `AirDrag` -> `drag`
- `Loss` -> `rest_cost` (higher loss = higher stop tendency)
- `Hardness` -> `cohesion` (proxy)
- `Advection` -> lower `lateral_cost`

These are not one-to-one in physical units; they are normalized to 0–1-ish scale and tuned for stability and visual plausibility.

## 4) Current Material Defaults
See `godot/project/data/materials.json` for current values (sand, water, glass, invisible). These were initialized using the reference field semantics and then normalized for the current sim scale.

## 5) Extending Materials
When adding a new material:
1. Collect reference values (Sandboxels and/or Powder Toy).
2. Normalize into the canonical fields.
3. Add an entry to `materials.json`.
4. Ensure rendering palette and material IDs are updated if needed.
