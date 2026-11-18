[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$logFile = 'C:\NpgLab\variant-launch.jsonl'
$events = @()
if (Test-Path $logFile) {
  foreach ($line in Get-Content -LiteralPath $logFile) {
    try {
      $j = $line | ConvertFrom-Json
      $data = if ($j.data.PSObject.Properties.Name.Count -gt 0) { ($j.data | ConvertTo-Json -Depth 4 -Compress) } else { '' }
      if ($data.Length -gt 3000) { $data = $data.Substring(0, 3000) + '...(truncated)' }
      $events += @{ type = $j.eventType; data = $data }
    } catch { $events += @{ type = 'unparsed'; data = $line.Substring(0, [Math]::Min(300, $line.Length)) } }
  }
}
$proc = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | ForEach-Object { @{ id = $_.Id; started = $_.StartTime.ToString('o') } })
$events | ConvertTo-Json -Depth 4 -Compress
'PROC:' + ($proc | ConvertTo-Json -Compress)
