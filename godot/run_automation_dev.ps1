param(
  [string]$ProjectPath = (Join-Path $PSScriptRoot "project"),
  [string]$Scene = "res://scenes/Main.tscn",
  [string]$AutomationHost = "127.0.0.1",
  [int]$AutomationPort = 24680,
  [string]$AutomationToken = "voxdebug"
)

$exe = Join-Path $PSScriptRoot "engine-bin\Godot_v4.5.1-automation-dev_win64.console.exe"
if (-not (Test-Path $exe)) {
  Write-Error "Missing editor binary: $exe"
  exit 1
}

$resolvedProject = Resolve-Path $ProjectPath
$automationEndpoint = "$AutomationHost`:$AutomationPort"

$args = @("--automation", $automationEndpoint, "--path", $resolvedProject, "--disable-crash-handler")
if ($AutomationToken -and $AutomationToken.Length -gt 0) {
  $args += @("--automation-token", $AutomationToken)
}
if ($Scene -and $Scene.Length -gt 0) {
  $args += $Scene
}

& $exe @args
