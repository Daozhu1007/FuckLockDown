$ErrorActionPreference = 'Stop'
$fixture = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 1800' -WindowStyle Hidden -PassThru
$launcher = Start-Process -FilePath 'C:\NpgLab\LockDownBrowser.NoProcessGate.exe' -ArgumentList '--log C:\NpgLab\variant-launch.jsonl' -WindowStyle Hidden -PassThru
@{ fixturePid=$fixture.Id; launcherPid=$launcher.Id; variant='process-policy-rewrite' } | ConvertTo-Json | Set-Content -LiteralPath 'C:\NpgLab\variant-processes.json' -Encoding UTF8
Get-Content -LiteralPath 'C:\NpgLab\variant-processes.json' -Raw
