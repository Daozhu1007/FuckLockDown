# Third-path experiment: run the REAL Iris inside the guest alongside the v2
# production launcher. Detached execution with incremental uploads.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$zipHash = 'cd357aa8e11d4247627df2f8cf42c5b520918f4400a2ec7a6c591301581bdd50'

function Publish-Iris([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 12 -Compress
    $reportDirectory = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory | Out-Null }
    [IO.File]::WriteAllText((Join-Path $reportDirectory $Name), $body, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    } catch { }
}

Publish-Iris 'iris-experiment-progress.json' @{state='downloading'}
Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/iris-vm.zip') -Headers $headers -OutFile (Join-Path $lab 'iris-vm.zip') -TimeoutSec 600
$actual = (Get-FileHash -LiteralPath (Join-Path $lab 'iris-vm.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $zipHash) { Publish-Iris 'iris-experiment.json' @{state='hash-mismatch'; got=$actual}; throw 'iris zip hash mismatch' }
Publish-Iris 'iris-experiment-progress.json' @{state='extracting'}
Expand-Archive -LiteralPath (Join-Path $lab 'iris-vm.zip') -DestinationPath (Join-Path $lab 'Iris') -Force
Publish-Iris 'iris-experiment-progress.json' @{state='starting-iris'}
Start-Process -FilePath (Join-Path $lab 'Iris\IrisPortable.exe')
Start-Sleep -Seconds 8
$irisNow = @(Get-Process | Where-Object { $_.Name -match 'iris' } | Select-Object -ExpandProperty Id)
Publish-Iris 'iris-experiment-progress.json' @{state='iris-started'; irisPids=$irisNow}

$launcher = Start-Process -FilePath (Join-Path $lab 'LockDownBrowser.NoProcessGate.exe') -ArgumentList '--no-ui','--log','C:\NpgLab\irislog1.jsonl' -WindowStyle Hidden -PassThru
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$dialogLog = @()
$lastDialogKey = ''
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
        Publish-Iris 'iris-experiment-partial.json' @{ t=$t; samples=$samples; state='running' }
    }
}
Publish-Iris 'iris-experiment.json' @{ state='done'; samples=$samples; end=[DateTimeOffset]::UtcNow.ToString('o') }
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
