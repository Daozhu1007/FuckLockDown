$ErrorActionPreference='Continue'
$c=Get-Content C:\NpgLab\config.json -Raw|ConvertFrom-Json
$h=@{'X-Lab-Token'=$c.token}
$lines=@(Get-Content -LiteralPath C:\NpgLab\hunter3.jsonl | Where-Object {$_.Trim()})
$events=@($lines|ForEach-Object{$_|ConvertFrom-Json})
$summary=@()
foreach($e in $events){
  switch($e.eventType){
    'heap_scan' {
      $items=@($e.data.items)
      $top=@($items | Select-Object -First 6 | ForEach-Object { @{pattern=$_.pattern;address=$_.address;region=$_.region;regionSize=$_.regionSize} })
      $summary += @{type='heap_scan';findings=$e.data.findings;regionCount=@($items | ForEach-Object {$_.region} | Select-Object -Unique).Count;top=$top}
    }
    'state_pointer_slots' { $summary += @{type='state_pointer_slots';slots=@($e.data.slots | Select-Object -First 20)} }
    'final_samples' {
      $s=@($e.data.samples)
      $changes=@()
      for($i=1;$i -lt $s.Count;$i++){
        if(($s[$i].alive -join ',') -ne ($s[$i-1].alive -join ',') -or $s[$i].selected -ne $s[$i-1].selected){
          $changes += @{t=$s[$i].seconds;selected=$s[$i].selected;alive=$s[$i].alive}
        }
      }
      $summary += @{type='final_samples';count=$s.Count;changes=$changes;last=$s[-1]}
    }
    default { $summary += @{type=$e.eventType;data=$e.data} }
  }
}
$payload=@{summary=$summary}|ConvertTo-Json -Depth 10 -Compress
Invoke-RestMethod -Uri ($c.endpoint+'/upload/hunter3-summary.json') -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 | Out-Null
Write-Output ('summary uploaded; raw lines: '+$lines.Count)
