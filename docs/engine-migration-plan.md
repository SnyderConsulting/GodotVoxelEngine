# VoxLand Engine Refactor / Migration Plan

This plan migrates the current project‑level voxel renderer + sim into the Godot engine as a dedicated voxel‑physics subsystem. A baseline engine module now exists at `godot/engine-src/modules/voxels`; the remaining phases here describe how to evolve and harden that module while keeping the project as a thin content layer.

## Goals

- Engine owns the voxel runtime: data layout, simulation, rendering, and lighting.
- Project owns content: scene construction, UI, and test setups.
- Unify voxel shape + lattice across the stack (BCC + truncated octahedron).
- Reduce project maintenance by migrating core GPU code into engine modules.

## Phase 0 — Baseline + Inventory

**Purpose**: Define what exists, where it lives, and what must be migrated.

Deliverables:
- Full list of project files tied to voxel core (renderer, sim, lighting, lattice).
- Separation of “engine candidates” vs “project content.”

Engine candidates (current project items):
- GPU renderer core (brickmap layout, atlas/indirection buffers, display pass).
- Voxel simulation kernel (sand movement).
- Lighting kernel (voxel flood‑fill).
- Voxel shape + lattice enforcement (truncated octahedron SDF + BCC parity).
- Material table / per‑material behavior (glass immobile + outline).
- Metrics + probe hooks.

Project content to remain:
- Scene generation and test logic (tumbler/hourglass/template).
- Gravity/world UI controls and orbit camera.

## Phase 1 — Engine Module Skeleton

**Purpose**: Create a new engine module (or editor‑side plugin backed by C++) that exposes engine‑level voxel components without changing behavior.

### Proposed engine classes

- **VoxelVolume** (Resource or Object)
  - Holds grid parameters (brick size, grid size, lattice spacing).
  - Holds material ID definitions + metadata (solid vs glass).
  - Exposes methods to upload voxel entries (sparse list or dense buffer).

- **VoxelRenderer** (Node3D)
  - Owns rendering resources (buffers, RD pipelines, UBO).
  - Exposes display texture for a quad or direct render path.
  - Accepts camera + world parameters (FOV, aspect, transform, max distance).
  - Provides metrics + debug probe callbacks.

- **VoxelSimulation** (Node or service)
  - Owns sim dispatch, active list construction, and indirect dispatch.
  - Exposes per‑frame stepping and sim rate controls.
  - Accepts gravity direction.

- **VoxelLighting** (Node or service)
  - Owns flood‑fill light pass.
  - Exposes lighting frequency + toggles.

### API surface (high‑level)

- `VoxelVolume.set_entries(entries, allocate_all_bricks)`
- `VoxelRenderer.set_volume(volume)`
- `VoxelRenderer.set_camera(camera)`
- `VoxelRenderer.set_world_rotation(rot_xyz)`
- `VoxelSimulation.set_volume(volume)`
- `VoxelSimulation.set_gravity_dir(vec3)`
- `VoxelLighting.set_volume(volume)`

## Phase 2 — Migrate GPU Layout + Buffers

**Purpose**: Move brickmap/atlas/occupancy/active‑list data layout into engine C++ and remove the GDScript implementation.

Tasks:
- Port atlas, indirection, occupancy buffers to C++ (RenderingDevice).
- Implement the double‑buffered atlas swap for simulation.
- Integrate occupancy + active list passes into a common command flow.
- Preserve the UBO layout (grid size, origin, camera, misc, world rotation).

Outcome:
- Project no longer allocates or updates GPU buffers.

## Phase 3 — Migrate Simulation Kernel

**Purpose**: Make the sand movement model engine‑owned.

Tasks:
- Move the compute shader for sim into engine shader assets.
- Bind it to `VoxelSimulation` with the same uniform layout.
- Expose controls: `sim_enabled`, `sim_every`, `sim_clear_output`.
- Keep material behavior consistent (glass immobile, sand movable).

Outcome:
- Project has no sim GDScript.

## Phase 4 — Migrate Lighting Kernel

**Purpose**: Make flood‑fill lighting an engine pass.

Tasks:
- Port the light compute shader to engine assets.
- Bind it to `VoxelLighting`.
- Preserve current light propagation rules and max light range.

Outcome:
- Lighting is engine‑owned; project controls only toggles/frequency.

## Phase 5 — Migrate Raymarch + Shape + Lattice

**Purpose**: Ensure the engine owns voxel shape and lattice, not the project.

Tasks:
- Move the raymarch compute shader into engine assets.
- Embed BCC lattice rules (parity check, nearest BCC cell).
- Embed truncated‑octahedron SDF + normal estimation.
- Move glass outline rendering + shading logic into engine.

Outcome:
- Voxel shape is an engine decision, enforced consistently.

## Phase 6 — Engine‑Level Materials + Behaviors

**Purpose**: Replace hardcoded material IDs with a proper engine table.

Tasks:
- Add a small material registry (ID → properties):
  - `is_solid`, `is_glass`, `emits_light`, `render_mode`.
- Allow engine to treat glass as non‑blocking for light + non‑moving for sim.
- Keep palette default for now; plan for material overrides later.

Outcome:
- Material behavior becomes data‑driven, not shader‑constant.

## Phase 7 — Engine Rendering Integration

**Purpose**: Move display pipeline into engine (optional but recommended).

Tasks:
- Provide a full‑screen render target node or a direct draw path.
- Eliminate the project’s manual quad + `compute_display.gdshader`.

Outcome:
- Project only instantiates `VoxelRenderer` and sets a camera.

## Phase 8 — Project Cleanup

**Purpose**: Convert project scripts into thin orchestration.

Tasks:
- Replace project’s `VoxelRenderer.gd` usage with engine classes.
- Keep scene builders (tumbler/hourglass/template) but remove GPU logic.
- Keep gravity/world rotation UI; it should talk to engine API.

Outcome:
- Project is content‑only, minimal maintenance.

## Phase 9 — Tests + Validation

**Purpose**: Ensure behavior matches current results.

Tests to build:
- Visual equivalence: tumbler/hourglass outputs match prior engine build.
- Simulation parity: sand moves the same under identical gravity.
- Lighting parity: light distribution matches previous run.
- Performance baseline: render step counts and active bricks comparable.

## Engine‑Side File Structure (Suggested)

- `modules/voxels/`
  - `voxel_volume.h/.cpp`
  - `voxel_renderer.h/.cpp`
  - `voxel_simulation.h/.cpp`
  - `voxel_lighting.h/.cpp`
  - `voxel_materials.h/.cpp`
  - `shaders/compute_raymarch.glsl`
  - `shaders/compute_sim.glsl`
  - `shaders/compute_light.glsl`
  - `shaders/compute_occupancy.glsl`
  - `shaders/compute_active_list.glsl`
  - `shaders/compute_active_dispatch.glsl`

## Migration Risks + Mitigations

- **Behavior drift**: Keep shader code identical at first. Only refactor structure.
- **Performance regression**: Keep brick‑skip DDA, active list, and indirect dispatch.
- **Render output mismatch**: Keep identical UBO layout and camera math.
- **Debug blind spots**: Preserve metrics/probe hooks.

## Recommended Order of Work

1) Engine module scaffolding + data layout (Phase 1–2).
2) Sim + lighting pass migration (Phase 3–4).
3) Raymarch + lattice + material behavior (Phase 5–6).
4) Render integration + project cleanup (Phase 7–8).
5) Testing + profiling (Phase 9).

## Notes for the Team

This plan intentionally **does not change behavior** at first. It lifts the existing GDScript + shader logic into engine code, then gradually replaces ad‑hoc constants with engine‑owned data tables. Once parity is achieved, the team can evolve the physics without breaking test scenes.
