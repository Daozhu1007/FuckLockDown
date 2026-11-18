[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if (Test-Path 'C:\NpgLab\phase-variant-delayed.jsonl') {
  Get-Content 'C:\NpgLab\phase-variant-delayed.jsonl' | ForEach-Object { $_ }
} else { Write-Output 'no log file' }
