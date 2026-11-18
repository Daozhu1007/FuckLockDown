$ErrorActionPreference='Continue'
$c=Get-Content C:\NpgLab\config.json -Raw|ConvertFrom-Json
$h=@{'X-Lab-Token'=$c.token}
$t='C:\NpgLab\hunter3.jsonl'
$lines=@(Get-Content -LiteralPath $t | Where-Object {$_.Trim()})
$payload=@{trace=@($lines|ForEach-Object{$_|ConvertFrom-Json})}|ConvertTo-Json -Depth 16 -Compress
Invoke-RestMethod -Uri ($c.endpoint+'/upload/hunter3-trace.json') -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 | Out-Null
Write-Output ('hunter3 trace uploaded: '+$lines.Count+' events')
