param(
  [string]$ServerHost = "127.0.0.1",
  [int]$Port = 24680,
  [string]$Token = "voxdebug",
  [int]$Steps = 24,
  [double]$YawStart = 0.0,
  [double]$YawEnd = 6.283185307179586,
  [double]$Pitch = -0.35,
  [int]$SleepMs = 200,
  [int]$ProbeX = 12,
  [int]$ProbeY = 12,
  [int]$ProbeZ = 12,
  [int]$ProbeStride = 0,
  [int]$DebugLogEvery = 30,
  [int]$DebugProbeEvery = 30,
  [int]$MetricsEvery = 30,
  [bool]$SimEnabled = $true,
  [int]$SimEvery = 1,
  [switch]$RenderThreadPing
)

$client = Join-Path $PSScriptRoot "automation_client.ps1"
if (-not (Test-Path $client)) {
  Write-Error "Missing automation client: $client"
  exit 1
}

$voxelPath = "/root/Main/VoxelRenderer"
$orbitPath = "/root/Main/OrbitRig"

function Invoke-Automation {
  param(
    [string]$Method,
    [hashtable]$Params = @{}
  )

  $paramsJson = "{}"
  if ($Params -and $Params.Count -gt 0) {
    $paramsJson = $Params | ConvertTo-Json -Compress
  }

  $respLines = & $client -ServerHost $ServerHost -Port $Port -Token $Token -Method $Method -ParamsJson $paramsJson
  $lastLine = $respLines | Select-Object -Last 1
  if (-not $lastLine) {
    throw "No response from automation server."
  }
  $resp = $lastLine | ConvertFrom-Json
  if (-not $resp.ok) {
    throw "Automation error: $($resp.error)"
  }
  return $resp
}

try {
  $ping = Invoke-Automation -Method "ping"
  Write-Host "Automation ping: $($ping.result)"

  $chunkGrid = [int](Invoke-Automation -Method "get" -Params @{ path = $voxelPath; property = "chunk_grid" }).result
  $chunkSize = [int](Invoke-Automation -Method "get" -Params @{ path = $voxelPath; property = "chunk_size" }).result
  $gridExtent = $chunkGrid * $chunkSize
  Write-Host "grid_extent=$gridExtent chunk_grid=$chunkGrid chunk_size=$chunkSize"

  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_logging"; value = $true } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_log_every"; value = $DebugLogEvery } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_probe_enabled"; value = $true } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_probe_every"; value = $DebugProbeEvery } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "metrics_every"; value = $MetricsEvery } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "sim_enabled"; value = $SimEnabled } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "sim_every"; value = $SimEvery } | Out-Null
  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_render_thread_ping"; value = $RenderThreadPing.IsPresent } | Out-Null

  Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_probe_cell"; value = @($ProbeX, $ProbeY, $ProbeZ) } | Out-Null

  if ($Steps -lt 1) {
    $Steps = 1
  }

  for ($i = 0; $i -le $Steps; $i++) {
    $ratio = $i / [double]$Steps
    $yaw = $YawStart + ($YawEnd - $YawStart) * $ratio
    $cellX = $ProbeX + ($i * $ProbeStride)
    if ($gridExtent -gt 0) {
      $cellX = (($cellX % $gridExtent) + $gridExtent) % $gridExtent
    }

    Invoke-Automation -Method "set" -Params @{ path = $voxelPath; property = "debug_probe_cell"; value = @($cellX, $ProbeY, $ProbeZ) } | Out-Null
    Invoke-Automation -Method "set" -Params @{ path = $orbitPath; property = "rotation"; value = @($Pitch, $yaw, 0.0) } | Out-Null
    Write-Host ("step={0} yaw={1:F3} cell=({2},{3},{4})" -f $i, $yaw, $cellX, $ProbeY, $ProbeZ)
    Start-Sleep -Milliseconds $SleepMs
  }
} catch {
  Write-Error $_
  exit 1
}
