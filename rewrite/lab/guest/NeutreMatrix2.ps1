# Ablation matrix v2: which neutre group the original's early phase reacts to.
# The trace (child_exit + timestamps) is the ground truth; the name-based
# process sampling in matrix v1 was unreliable from the detached script.
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
    $trace = Join-Path $lab ('neutre2-' + $Name + '.jsonl')
    Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue
    $allArgs = @('--no-ui','--log',$trace) + $ExtraArgs
    $launcher = Start-Process -FilePath $experiment -ArgumentList $allArgs -WindowStyle Hidden -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $started = [DateTimeOffset]::UtcNow
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        Start-Sleep -Milliseconds 500
        $events = Read-Trace $trace
        if (@($events | Where-Object eventType -eq 'child_exit').Count) { break }
        if (@($events | Where-Object eventType -eq 'error').Count) { break }
    }
    $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $events = Read-Trace $trace
    $digest = @($events | Where-Object { $_.eventType -in @('image_data_neutralized','policy_activated','policy_data_verified','child_exit','error') } |
        ForEach-Object { @{ time=$_.time; eventType=$_.eventType; data=$_.data } })
    Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    return @{ phase=$Name; args=$ExtraArgs; elapsed=$elapsed; trace=$digest }
}

$results = @()
foreach ($phase in @(
    @{ name='keep-alpha'; args=@('--data-neutres-keep','alpha') },
    @{ name='keep-beta';  args=@('--data-neutres-keep','beta') },
    @{ name='keep-gamma'; args=@('--data-neutres-keep','gamma') },
    @{ name='keep-ptc4';  args=@('--data-neutres-keep','ptc4') },
    @{ name='skip-key';   args=@('--data-neutres-skip','alpha-process-list-key') }
)) {
    $results += Run-Phase $phase.name $phase.args
    Publish-Watch 'neutre-matrix2-partial.json' @{ done=@($results | ForEach-Object { $_.phase }) }
}
Publish-Watch 'neutre-matrix2.json' @{ results=$results }
Write-Output 'neutre-matrix2.json published'
