# Ablation matrix for the v3 image-data neutres: three launcher phases with
# different neutre settings, each sampled for 45 s. Discriminates whether the
# pre-resume .rdata corruption dies from an early-phase image check (then the
# activation-timing variant survives) or from a startup read of a corrupted
# string (then every variant dies and the neutre set needs refinement).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$experiment = Join-Path $lab 'ExperimentLauncher.exe'

function Publish-Watch([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 14 -Compress
    $reportDirectory = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory | Out-Null }
    [IO.File]::WriteAllText((Join-Path $reportDirectory $Name), $body, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    } catch { }
}

function Read-Trace([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

function Run-Phase([string]$Name, [string[]]$ExtraArgs) {
    taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $trace = Join-Path $lab ('neutre-' + $Name + '.jsonl')
    Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue
    $allArgs = @('--no-ui','--log',$trace) + $ExtraArgs
    $launcher = Start-Process -FilePath $experiment -ArgumentList $allArgs -WindowStyle Hidden -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $alive = @()
    while ($sw.Elapsed.TotalSeconds -lt 45) {
        Start-Sleep -Milliseconds 500
        $events = Read-Trace $trace
        $exited = @($events | Where-Object eventType -eq 'child_exit')
        $alive += @{ t = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
                     launcher = [bool](Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)
                     browser = @((Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue)).Count -gt 0 }
        if ($exited.Count) { break }
    }
    $events = Read-Trace $trace
    $digest = @($events | Where-Object { $_.eventType -in @('image_data_neutralized','policy_activated','policy_data_verified','child_exit','error') } |
        ForEach-Object { @{ time=$_.time; eventType=$_.eventType; data=$_.data } })
    Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    return @{ phase=$Name; args=$ExtraArgs; alive=$alive; trace=$digest }
}

$results = @()
$results += Run-Phase 'no-neutres'   @('--no-data-neutres')
Publish-Watch 'neutre-matrix-partial.json' @{ done=@('no-neutres') }
$results += Run-Phase 'suspend'      @()
Publish-Watch 'neutre-matrix-partial.json' @{ done=@('no-neutres','suspend') }
$results += Run-Phase 'activation'   @('--data-neuter-timing','activation')
Publish-Watch 'neutre-matrix.json' @{ results=$results }
Write-Output 'neutre-matrix.json published'
