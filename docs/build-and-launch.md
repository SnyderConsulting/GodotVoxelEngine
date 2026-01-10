# Build & Launch (Godot + VoxLand)

Centralized steps to rebuild the engine, stage binaries, and launch the app/automation without losing required sources.

## Engine build
- Workdir: `godot/engine-src`
- Required module: `modules/voxels/` must exist (tracked source of truth lives here, not in project scripts).
- Command (template_debug, no editor tools, keep path overrides so project assets resolve):
```
scons -j8 platform=windows target=template_debug tools=no disable_path_overrides=no
```
- Outputs: `bin/godot.windows.template_debug.x86_64.exe` and `bin/godot.windows.template_debug.x86_64.console.exe`.

## Stage binaries for scripts
Copy the freshly built binaries into `godot/engine-bin/` with the names the launchers expect:
```
cd godot/engine-src/bin
Copy-Item godot.windows.template_debug.x86_64.exe ..\engine-bin\Godot_v4.5.1-automation-dev_win64.exe
Copy-Item godot.windows.template_debug.x86_64.console.exe ..\engine-bin\Godot_v4.5.1-automation-dev_win64.console.exe
```
(`engine-bin/` and `engine-src/bin/` are build artifacts and remain git-ignored; sources stay under `engine-src/`.)

## Launch commands (project root)
- Game (windowed): `godot/run_game_dev.ps1 -Detached`
- Automation server (console): `godot/run_automation_dev.ps1 -Detached -AutomationToken voxdebug [-Scene "res://scenes/TumblerTest.tscn"]`
- Editor (if needed): `godot/run_editor_dev.ps1`
- See `docs/dev-run-notes.md` for why `-Detached` avoids Codex job teardown.

## Automation quick-check
1) Start automation with the command above.
2) Verify port/token: defaults to `127.0.0.1:24680` / `voxdebug` unless overridden.
3) Screenshot sanity test:
```
godot/automation_client.ps1 -ServerHost 127.0.0.1 -Port 24680 -Token voxdebug -Method screenshot -ParamsJson '{\"path\":\"user://automation_frame.png\"}'
```
`user://automation_frame.png` should show the tumbler scene with voxel sand; failure usually means missing voxel module or wrong binary copy.

## Remote hygiene
- Root and project repos currently have no remotes; add explicit remotes before pushing:
```
git remote add origin <your-project-url>
```
- Engine repo has `origin` set to upstream `https://github.com/godotengine/godot.git`; avoid pushing there unless intentional. Prefer a fork remote for engine contributions.

## Common pitfalls to avoid
- White/blank render: voxel module missing from `engine-src/modules/voxels` or wrong binary copied to `engine-bin/`.
- CLI closes Godot instantly: rerun with `-Detached` (see `docs/dev-run-notes.md`).
- Wrong binary names/locations: always copy after each rebuild; scripts only look in `godot/engine-bin/`.
