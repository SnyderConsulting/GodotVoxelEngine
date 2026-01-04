param(
  [string]$ServerHost = "127.0.0.1",
  [int]$Port = 24680,
  [string]$Token = "",
  [string]$Method = "ping",
  [string]$ParamsJson = "{}",
  [int]$Id = 1
)

$client = [System.Net.Sockets.TcpClient]::new()
$client.Connect($ServerHost, $Port)
$stream = $client.GetStream()
$writer = [System.IO.StreamWriter]::new($stream, [System.Text.Encoding]::UTF8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true
$reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)

function Send-JsonLine([string]$line) {
  $writer.WriteLine($line)
  return $reader.ReadLine()
}

if ($Token -and $Token.Length -gt 0) {
  $authObj = @{
    id = 0
    method = "auth"
    params = @{ token = $Token }
  }
  $authJson = $authObj | ConvertTo-Json -Compress
  $authResp = Send-JsonLine $authJson
  Write-Output $authResp
}

try {
  $paramsObj = if ($ParamsJson -and $ParamsJson.Length -gt 0) { $ParamsJson | ConvertFrom-Json } else { @{} }
} catch {
  $paramsObj = @{}
}

$payloadObj = @{
  id = $Id
  method = $Method
  params = $paramsObj
}
$payloadJson = $payloadObj | ConvertTo-Json -Compress
$response = Send-JsonLine $payloadJson
Write-Output $response

$reader.Dispose()
$writer.Dispose()
$client.Dispose()
