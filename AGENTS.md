# VoxLand Engine DX Loop

We treat this repo as the engine source + build artifacts. The “project” side is just for prototyping to evaluate the engine’s developer experience.

Cycle:
1) Prototype/demos: build small scenes to feel out the engine like a game developer would.
2) Capture needs: note “nice to have” or missing features from the prototype experience.
3) Update engine: implement changes in `godot/engine-src` to serve those needs.
4) DX check: ensure changes align with `docs/dx-ergonomics.md`.
5) Automated tests: run available checks to guard against regressions.
6) Build artifact: rebuild engine binaries and hand them to devs for evaluation.
7) Repeat from step 1.

Reference: `docs/dx-ergonomics.md` for DX/ergonomics principles to apply at step 4.
