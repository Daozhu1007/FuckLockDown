[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference='Continue'
$log = 'C:\NpgLab\exp-trace.jsonl'
if (Test-Path $log) { Get-Content -LiteralPath $log | ForEach-Object { $_.Substring(0, [Math]::Min(400, $_.Length)) } } else { 'no log file' }
