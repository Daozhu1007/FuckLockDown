$ErrorActionPreference='Continue'
$c=Get-Content C:\NpgLab\config.json -Raw|ConvertFrom-Json
$h=@{'X-Lab-Token'=$c.token}
$lines=@(Get-Content -LiteralPath C:\NpgLab\hunter5.jsonl | Where-Object {$_.Trim()})
$events=@($lines|ForEach-Object{$_|ConvertFrom-Json})
$summary=@()
foreach($e in $events){
  switch($e.eventType){
    'heap_scan' {
      $items=@($e.data.items)
      $summary += @{type='heap_scan';findings=$e.data.findings}
    }
    'final_samples' {
      $s=@($e.data.samples)
      $changes=@()
      $head=@()
      for($i=0;$i -lt $s.Count;$i++){
        if($i -lt 6){ $head += $s[$i] }
        if($i -gt 0){
          $gateChanged = (($s[$i].gate | ConvertTo-Json -Compress) -ne ($s[$i-1].gate | ConvertTo-Json -Compress))
          if(($s[$i].alive -join ',') -ne ($s[$i-1].alive -join ',') -or $s[$i].selected -ne $s[$i-1].selected -or $gateChanged){
            $changes += @{t=$s[$i].seconds;selected=$s[$i].selected;gate=$s[$i].gate;alive=$s[$i].alive}
          }
        }
      }
      $summary += @{type='final_samples';count=$s.Count;head=$head;changes=$changes;last=$s[-1]}
    }
    default { $summary += @{type=$e.eventType;data=$e.data} }
  }
}
$payload=@{summary=$summary}|ConvertTo-Json -Depth 10 -Compress
Invoke-RestMethod -Uri ($c.endpoint+'/upload/hunter5-summary.json') -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 60 | Out-Null
Write-Output ('hunter5 summary uploaded; raw lines: '+$lines.Count)
