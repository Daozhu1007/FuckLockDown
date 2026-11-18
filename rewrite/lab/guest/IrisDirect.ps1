# Round 2: start the REAL Iris app directly (bypassing the portable wrapper),
# then run the v2 production launcher and watch survival for 90 seconds.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }

function Publish-Iris([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 12 -Compress
    $reportDirectory = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory | Out-Null }
    [IO.File]::WriteAllText((Join-Path $reportDirectory $Name), $body, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    } catch { }
}

Get-Process -Name IrisPortable -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$real = Start-Process -FilePath (Join-Path $lab 'Iris\App\Iris\Iris.exe') -PassThru
Start-Sleep -Seconds 10
$irisNow = @(Get-Process | Where-Object { $_.Name -match 'iris' } | Select-Object -ExpandProperty Id)
Publish-Iris 'iris2-progress.json' @{state='real-iris-started'; irisPids=$irisNow; directPid=$real.Id}

$launcher = Start-Process -FilePath (Join-Path $lab 'LockDownBrowser.NoProcessGate.exe') -ArgumentList '--no-ui','--log','C:\NpgLab\irislog2.jsonl' -WindowStyle Hidden -PassThru
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$lastUpload = -1
while ($elapsed.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    $iris = @(Get-Process | Where-Object { $_.Name -match 'iris' })
    $browser = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue)
    $samples += @{ t = $t
                   irisCount = $iris.Count
                   irisPids = @($iris | ForEach-Object { $_.Id })
                   browserAlive = $browser.Count -gt 0 }
    if ([int]$t -ne $lastUpload -and [int]$t % 10 -eq 0) {
        $lastUpload = [int]$t
        Publish-Iris 'iris2-partial.json' @{ t=$t; samples=$samples; state='running' }
    }
}
Publish-Iris 'iris2-result.json' @{ state='done'; samples=$samples; end=[DateTimeOffset]::UtcNow.ToString('o') }
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
