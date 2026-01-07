# Dev Run Notes (Codex CLI + Windows)

## Summary
- Godot started from Codex CLI can exit as soon as the tool finishes, even if the window was visible.
- This is caused by the Codex CLI job/process teardown (PowerShell + job objects) killing child processes when the parent session ends.
- `Start-Process` is not sufficient to detach when the parent is running inside a managed job.

## Fix (Detaching the Process)
We added a scheduled-task based launcher to escape the Codex job:
- `godot/run_game_dev.ps1 -Detached`
- `godot/run_automation_dev.ps1 -Detached -AutomationToken voxdebug`

These create a one-off Scheduled Task, start Godot out-of-band, then immediately unregister the task. The Godot window stays open after the CLI response ends.

## Common Symptoms
- Godot opens, then closes right when the CLI stops "waiting for background terminal".
- This happens even though there are no fatal errors in the Godot logs.

## Launcher Notes
- `godot/run_game_dev.ps1` uses the windowed `Godot_v4.5.1-automation-dev_win64.exe`.
- `godot/run_automation_dev.ps1` uses the console build with `--automation` and supports:
  - `-AutoPort` (default) to pick a free port if 24680 is busy.
  - `-KillExisting` to stop old automation sessions.
  - `-Detached` to escape the Codex job.

## Quick Verification
After a detached launch, confirm the process is alive:
```
Get-Process | Where-Object { $_.ProcessName -match "Godot_v4.5.1-automation-dev_win64" }
```
