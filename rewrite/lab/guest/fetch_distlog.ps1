$ErrorActionPreference='Continue'
$c=Get-Content C:\NpgLab\config.json -Raw|ConvertFrom-Json
$h=@{'X-Lab-Token'=$c.token}
$t='C:\NpgLab\distlog.jsonl'
if(Test-Path -LiteralPath $t){
  $lines=@(Get-Content -LiteralPath $t | Where-Object {$_.Trim()})
  $payload=@{trace=@($lines|ForEach-Object{$_|ConvertFrom-Json})}|ConvertTo-Json -Depth 12 -Compress
  Invoke-RestMethod -Uri ($c.endpoint+'/upload/distlog.json') -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 30 | Out-Null
  Write-Output ('distlog uploaded: '+$lines.Count+' events')
} else { Write-Output 'missing distlog' }
