# Last Stable State Snapshot (2026-01-09 18:42:56)

## Issues Encountered
- Engine builds were missing the voxel module (`VoxelRenderer`), causing scenes to instantiate placeholders and rendering a white screen.
- Duplicate MPM metrics members/functions in `modules/voxels/voxel_renderer.{h,cpp}` caused SCons compilation failures after restoring the voxel module.
- Automation server was not listening on 24680 when launched attached; the client saw `target machine actively refused` errors.
- WASAPI initialization fails on this machine; audio falls back to the dummy driver (benign for automation/testing).

## Resolutions Applied
- Re-applied the stashed voxel module and rebuilt the engine with `disable_path_overrides=no` and `tools=no template_debug`. Copied the resulting `godot.windows.template_debug.x86_64{.console}.exe` into `godot/engine-bin` as the runtime binaries.
- Removed duplicated MPM metrics fields, uniforms, and pipelines from `voxel_renderer` to fix build errors; kept the renderer functional for sand scenes.
- Launched automation detached via `godot/run_automation_dev.ps1 -Detached -AutomationToken voxdebug -Scene "res://scenes/TumblerTest.tscn"`, which brought up the listener on 127.0.0.1:24680.
- Verified automation with `automation_client.ps1` ping and captured a working screenshot (`automation_frame.png`) showing the tumbler + sand rendered correctly.

## Tips for Future Incidents
- If Godot shows a white screen, confirm the voxel module exists and `VoxelRenderer` is registered. Rebuild with the module present and copy binaries to `godot/engine-bin`.
- For automation, always use `run_automation_dev.ps1 -Detached ...` to escape CLI job teardown, then ping with `automation_client.ps1 -Method ping`.
- WASAPI errors can be ignored for automation; audio will fall back to dummy.
- If SCons fails in `voxel_renderer` with duplicate members, remove the extra MPM metrics fields and rebuild.
- Binaries need `disable_path_overrides=no` to allow `--path` in launch scripts.

## Current Project State
- Engine rebuilt and binaries in `godot/engine-bin` include the voxel module; voxel scenes render correctly under automation.
- Automation server reachable on 127.0.0.1:24680 with token `voxdebug`; latest run rendered `res://scenes/TumblerTest.tscn` successfully (see `automation_frame.png` in `%APPDATA%/Godot/app_userdata/VoxLand`).
- Git: engine-src has local changes (voxel module + metrics cleanup) not committed; project repo clean. One stash remains in engine (`temp-stash` consumed when reapplying module).
- Launch commands:
  - Game: `godot/run_game_dev.ps1 -Detached`
  - Automation: `godot/run_automation_dev.ps1 -Detached -AutomationToken voxdebug [-Scene <tscn>]`
  - Automation client example: `godot/automation_client.ps1 -ServerHost 127.0.0.1 -Port 24680 -Token voxdebug -Method screenshot -ParamsJson '{"path":"user://snap.png"}'`
