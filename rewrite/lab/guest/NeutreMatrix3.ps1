# Ablation matrix v3: bisect the lethal groups (beta/gamma/ptc4) down to the
# individual strings. keep-alpha survived matrix v2, so the launcher machinery
# and the alpha-region writes are a healthy baseline.
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
    $trace = Join-Path $lab ('neutre3-' + $Name + '.jsonl')
    Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue
    $allArgs = @('--no-ui','--log',$trace) + $ExtraArgs
    $launcher = Start-Process -FilePath $experiment -ArgumentList $allArgs -WindowStyle Hidden -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        Start-Sleep -Milliseconds 500
        $events = Read-Trace $trace
        if (@($events | Where-Object eventType -eq 'child_exit').Count) { break }
        if (@($events | Where-Object eventType -eq 'error').Count) { break }
    }
    $elapsed = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $events = Read-Trace $trace
    $digest = @($events | Where-Object { $_.eventType -in @('image_data_neutralized','policy_activated','child_exit','error') } |
        ForEach-Object { @{ time=$_.time; eventType=$_.eventType; data=$_.data } })
    Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    return @{ phase=$Name; args=$ExtraArgs; elapsed=$elapsed; trace=$digest }
}

$phases = @(
    @{ name='wql-only';    args=@('--data-neutres-keep','gamma','--data-neutres-skip','gamma-wireless-display-toolbar') },
    @{ name='toolbar-only';args=@('--data-neutres-keep','gamma','--data-neutres-skip','gamma-wudfhost-wql') },
    @{ name='ptc4-first4'; args=@('--data-neutres-keep','ptc4','--data-neutres-skip','ptc4-aswtoolssvc','--data-neutres-skip','ptc4-avgtoolssvc','--data-neutres-skip','ptc4-avpmapp') },
    @{ name='ptc4-av3';    args=@('--data-neutres-keep','ptc4','--data-neutres-skip','ptc4-scriptlogic','--data-neutres-skip','ptc4-pgxsrv','--data-neutres-skip','ptc4-ssxsrv','--data-neutres-skip','ptc4-efrservice','--data-neutres-skip','ptc4-sshxsrv') },
    @{ name='beta-office'; args=@('--data-neutres-keep','beta','--data-neutres-skip','beta-stickykeys','--data-neutres-skip','beta-sticky-keys','--data-neutres-skip','beta-message','--data-neutres-skip','beta-message-from-web','--data-neutres-skip','beta-discussion','--data-neutres-skip','beta-print','--data-neutres-skip','beta-wireless-display-toolbar') },
    @{ name='beta-caption';args=@('--data-neutres-keep','beta','--data-neutres-skip','beta-xlmain','--data-neutres-skip','beta-opusapp','--data-neutres-skip','beta-autohotkeygui','--data-neutres-skip','beta-save-a','--data-neutres-skip','beta-select-file','--data-neutres-skip','beta-power-options') }
)
$results = @()
foreach ($phase in $phases) {
    $results += Run-Phase $phase.name $phase.args
    Publish-Watch 'neutre-matrix3-partial.json' @{ done=@($results | ForEach-Object { $_.phase }) }
}
Publish-Watch 'neutre-matrix3.json' @{ results=$results }
Write-Output 'neutre-matrix3.json published'
