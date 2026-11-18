[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$logFile = 'C:\NpgLab\variant-launch.jsonl'
$events = @()
if (Test-Path $logFile) {
  foreach ($line in Get-Content -LiteralPath $logFile) {
    try {
      $j = $line | ConvertFrom-Json
      $events += @{ time = $j.time; type = $j.eventType }
    } catch { }
  }
}
$events | ConvertTo-Json -Depth 3 -Compress
