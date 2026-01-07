param(
  [string]$ProjectPath = (Join-Path $PSScriptRoot "project"),
  [switch]$Wait,
  [switch]$Detached
)

$exe = Join-Path $PSScriptRoot "engine-bin\Godot_v4.5.1-automation-dev_win64.exe"
if (-not (Test-Path $exe)) {
  Write-Error "Missing editor binary: $exe"
  exit 1
}

$resolvedProject = Resolve-Path $ProjectPath

function Join-CommandLine([string[]]$Parts) {
  $encoded = @()
  foreach ($part in $Parts) {
    if ($part -match '[\\s"]') {
      $escaped = $part -replace '"', '\\"'
      $encoded += '"' + $escaped + '"'
    } else {
      $encoded += $part
    }
  }
  return ($encoded -join ' ')
}

function Start-Detached([string]$ExePath, [string[]]$Arguments) {
  $taskName = "VoxLandDetached_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
  $argumentString = Join-CommandLine $Arguments
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
  $action = New-ScheduledTaskAction -Execute $ExePath -Argument $argumentString
  $userId = $env:USERNAME
  if (-not $userId) {
    $userId = [Environment]::UserName
  }
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Seconds 2
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
  Write-Host "Started detached task: $taskName"
}

if ($Detached) {
  Start-Detached -ExePath $exe -Arguments @("--path", $resolvedProject)
  return
}

if ($Wait) {
  & $exe --path $resolvedProject
  return
}

Start-Process -FilePath $exe -ArgumentList @("--path", $resolvedProject) -WorkingDirectory $resolvedProject | Out-Null
