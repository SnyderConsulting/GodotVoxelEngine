param(
  [string]$ProjectPath = (Join-Path $PSScriptRoot "project"),
  [string]$Scene = "res://scenes/ProtoHub.tscn",
  [string]$AutomationHost = "127.0.0.1",
  [int]$AutomationPort = 24680,
  [string]$AutomationToken = "voxdebug",
  [switch]$AutoPort = $true,
  [switch]$KillExisting,
  [switch]$Detached
)

function Resolve-ListenAddress([string]$HostName) {
  $ip = $null
  if ([System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) {
    return $ip
  }
  if ($HostName -eq "localhost") {
    return [System.Net.IPAddress]::Loopback
  }
  return [System.Net.IPAddress]::Any
}

function Test-PortAvailable([System.Net.IPAddress]$Address, [int]$Port) {
  try {
    $listener = [System.Net.Sockets.TcpListener]::new($Address, $Port)
    $listener.Start()
    $listener.Stop()
    return $true
  } catch {
    return $false
  }
}

function Find-FreePort([System.Net.IPAddress]$Address, [int]$StartPort, [int]$MaxAttempts = 50) {
  for ($i = 0; $i -lt $MaxAttempts; $i++) {
    $port = $StartPort + $i
    if (Test-PortAvailable -Address $Address -Port $port) {
      return $port
    }
  }
  return $null
}

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

$exe = Join-Path $PSScriptRoot "engine-bin\Godot_v4.5.1-automation-dev_win64.console.exe"
if (-not (Test-Path $exe)) {
  Write-Error "Missing editor binary: $exe"
  exit 1
}

$listenAddress = Resolve-ListenAddress $AutomationHost
if (-not (Test-PortAvailable -Address $listenAddress -Port $AutomationPort)) {
  if ($KillExisting) {
    Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessName -in @(
        "Godot_v4.5.1-automation-dev_win64",
        "Godot_v4.5.1-automation-dev_win64.console"
      ) } |
      Stop-Process -Force
    Start-Sleep -Milliseconds 300
  }
  if (-not (Test-PortAvailable -Address $listenAddress -Port $AutomationPort)) {
    if ($AutoPort) {
      $freePort = Find-FreePort -Address $listenAddress -StartPort $AutomationPort
      if ($null -eq $freePort) {
        Write-Error "No free automation ports found starting at $AutomationPort."
        exit 1
      }
      Write-Host "Automation port $AutomationPort busy; using $freePort."
      $AutomationPort = $freePort
    } else {
      Write-Error "Automation port $AutomationPort is in use. Use -KillExisting or -AutoPort."
      exit 1
    }
  }
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

if ($Detached) {
  Start-Detached -ExePath $exe -Arguments $args
  return
}

& $exe @args
