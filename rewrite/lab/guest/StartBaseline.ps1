$ErrorActionPreference = 'Stop'
$fixture = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 1800' -WindowStyle Hidden -PassThru
$browser = Start-Process -FilePath 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' -PassThru
@{ fixturePid=$fixture.Id; browserPid=$browser.Id; variant='unmodified-original' } | ConvertTo-Json | Set-Content -LiteralPath 'C:\NpgLab\baseline-processes.json' -Encoding UTF8
Get-Content -LiteralPath 'C:\NpgLab\baseline-processes.json' -Raw
