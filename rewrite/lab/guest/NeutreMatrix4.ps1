# Ablation matrix v4: with the alpha-only neutres applied (the v3.1 set),
# which decoy class makes the original exit 1. keep-alpha survived 40 s with
# no decoys present (matrix v2); the full-decoy acceptance run died at +15 s.
# Candidates: the gamma-matching WUDFHost.exe + MiraCast command line, the
# alpha-name decoys, and the window-class/caption decoys.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$experiment = Join-Path $lab 'ExperimentLauncher.exe'
$dir = Join-Path $lab '3rd'

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

function Spawn-Decoy([string]$Name, [string[]]$DecoyArgs) {
    $path = Join-Path $dir $Name
    Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path -Force
    return (Start-Process -FilePath $path -ArgumentList $DecoyArgs -WindowStyle Hidden -PassThru)
}

function Run-Phase([string]$Name, [scriptblock]$Setup, [string[]]$ExtraLauncherArgs = @()) {
    taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
    Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('WUDFHost.exe','Spyrix Monitor.exe','ReadAndWrite.exe','SelfService.exe') -or $_.CommandLine -match 'DecoyWindowsHost' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    $decoys = @(& $Setup)
    $trace = Join-Path $lab ('neutre4-' + $Name + '.jsonl')
    Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue
    $launcherArgs = @('--no-ui','--log',$trace) + $(if ($ExtraLauncherArgs.Count) { $ExtraLauncherArgs } else { @('--data-neutres-keep','alpha') }); $launcher = Start-Process -FilePath $experiment -ArgumentList $launcherArgs -WindowStyle Hidden -PassThru
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
    $decoyAlive = @($decoys | ForEach-Object { [bool](Get-Process -Id $_.Id -ErrorAction SilentlyContinue) })
    Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($d in $decoys) { Stop-Process -Id $d.Id -Force -ErrorAction SilentlyContinue }
    return @{ phase=$Name; elapsed=$elapsed; decoyAlive=$decoyAlive; trace=$digest }
}

$results = @()
$results += Run-Phase 'no-decoys'       { @() }
$results += Run-Phase 'no-neutres'      { @() } -ExtraLauncherArgs @('--no-data-neutres')

Publish-Watch 'neutre-matrix4-partial.json' @{ done=@('no-decoys','no-neutres') }
$results += Run-Phase 'skip-key'        { @() } -ExtraLauncherArgs @('--data-neutres-keep','alpha','--data-neutres-skip','alpha-process-list-key')
$results += Run-Phase 'wudfhost-miracast' { @(Spawn-Decoy 'WUDFHost.exe' @('/k','rem MiraCast wireless-display stub')) }
Publish-Watch 'neutre-matrix4-partial.json' @{ done=@('wudfhost-miracast') }
$results += Run-Phase 'spyrix-name'        { @(Spawn-Decoy 'Spyrix Monitor.exe' @('/k','rem spyrix decoy')) }
Publish-Watch 'neutre-matrix4-partial.json' @{ done=@('wudfhost-miracast','spyrix-name') }
$results += Run-Phase 'alpha-names'        { @(
    (Spawn-Decoy 'ReadAndWrite.exe' @('/k','rem rw decoy')),
    (Spawn-Decoy 'SelfService.exe' @('/k','rem Citrix Workspace SelfService.exe')) ) }
Publish-Watch 'neutre-matrix4-partial.json' @{ done=@('wudfhost-miracast','spyrix-name','alpha-names') }
$results += Run-Phase 'windows'            { @(Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'DecoyWindowsHost.ps1') -WindowStyle Hidden -PassThru) }
Publish-Watch 'neutre-matrix4.json' @{ results=$results }
Write-Output 'neutre-matrix4.json published'
