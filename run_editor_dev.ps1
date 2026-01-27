param(
  [string]$ProjectPath = (Join-Path $PSScriptRoot ".")
)

$exe = Join-Path $PSScriptRoot "engine-bin\Godot_v4.5.1-automation-dev_win64.console.exe"
if (-not (Test-Path $exe)) {
  Write-Error "Missing editor binary: $exe"
  exit 1
}

$resolvedProject = Resolve-Path $ProjectPath
& $exe --path $resolvedProject
