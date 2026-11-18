# Third kill-path reproduction with the ORIGINAL browser (control run).
# Decoys match the statically anchored needles: alpha 0x14022b1b0 names
# (WUDFHost.exe + MiraCast command line, Spyrix, ReadAndWrite.exe,
# SelfService.exe + Citrix Workspace command line), beta 0x140245530 window
# classes/captions (separate window-host process), gamma 0x140262690 WQL
# (WUDFHost + MiraCast), PTC4 0x140261340 service names (EFRService).
# The run records who dies and when, plus any close-app dialog and the
# browser's own log lines naming the killing branch.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$dir = Join-Path $lab '3rd'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }

function Publish-Watch([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 14 -Compress
    $reportDirectory = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory | Out-Null }
    [IO.File]::WriteAllText((Join-Path $reportDirectory $Name), $body, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    } catch { }
}

# --- decoys ---------------------------------------------------------------
$decoySpec = @(
    @{ name = 'WUDFHost.exe';        args = @('/k', 'rem MiraCast wireless-display stub') }
    @{ name = 'Spyrix Monitor.exe';  args = @('/k', 'rem spyrix decoy') }
    @{ name = 'ReadAndWrite.exe';    args = @('/k', 'rem readwrite decoy') }
    @{ name = 'SelfService.exe';     args = @('/k', 'rem Citrix Workspace SelfService.exe') }
)
$decoyPids = @()
foreach ($spec in $decoySpec) {
    $path = Join-Path $dir $spec.name
    Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path -Force
    $process = Start-Process -FilePath $path -ArgumentList $spec.args -WindowStyle Hidden -PassThru
    $decoyPids += $process.Id
}
& sc.exe create EFRService binPath= (Join-Path $dir 'ReadAndWrite.exe') start= demand | Out-Null
Remove-Item -LiteralPath (Join-Path $dir 'windowhost.pid') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $dir 'ui-events.log') -Force -ErrorAction SilentlyContinue
$windowHost = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'DecoyWindowsHost.ps1') -WindowStyle Hidden -PassThru
$windowHostPid = $windowHost.Id
Write-Output ('decoys: ' + ($decoyPids -join ',') + ' windowhost: ' + $windowHostPid)

# --- original browser -----------------------------------------------------
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
Start-Sleep -Seconds 3
$started = [DateTimeOffset]::UtcNow
$browser = Start-Process -FilePath 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' -WindowStyle Hidden -PassThru
$browserPid = $browser.Id
Write-Output ('original browser pid: ' + $browserPid)

$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$dialogLog = @()
$closeClicks = @()
$lastDialogKey = ''
$selected = $null
$lastUpload = -1
while ($elapsed.Elapsed.TotalSeconds -lt 150) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    $samples += @{ t = $t
                   browserAlive = [bool](Get-Process -Id $browserPid -ErrorAction SilentlyContinue)
                   decoys = @($decoyPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) })
                   windowHostAlive = [bool](Get-Process -Id $windowHostPid -ErrorAction SilentlyContinue) }
    if ([int]$t -ne $lastUpload -and [int]$t % 10 -eq 0) {
        $lastUpload = [int]$t
        Publish-Watch 'thirdpath-repro-partial.json' @{ t=$t; selectedServer=$selected; closeClicks=$closeClicks; samples=$samples }
    }
}

# --- browser log scan for kill-branch literals ----------------------------
$logHits = @()
foreach ($root in @("$env:LOCALAPPDATA\Respondus", "$env:ProgramData\Respondus", 'C:\Program Files\Respondus')) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $started -and $_.Length -lt 5MB } |
      ForEach-Object {
        $hit = @(Select-String -LiteralPath $_.FullName -Pattern 'KILLING','AUTOHOTKEY','WUDF found','Hack type','PTC','MiraCast','Spyrix','Wireless display' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 8)
        if ($hit.Count) { $logHits += @{ file=$_.FullName; lines=@($hit | ForEach-Object { $_.Line }) } }
      }
}

# --- cleanup ---------------------------------------------------------------
Get-Process -Id $browserPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
foreach ($decoyPid in $decoyPids) { Stop-Process -Id $decoyPid -Force -ErrorAction SilentlyContinue }
if ($windowHostPid) { Stop-Process -Id $windowHostPid -Force -ErrorAction SilentlyContinue }
& sc.exe delete EFRService | Out-Null

$uiEvents = @()
$uiLog = Join-Path $dir 'ui-events.log'
if (Test-Path -LiteralPath $uiLog) { $uiEvents = @(Get-Content -LiteralPath $uiLog) }
Publish-Watch 'thirdpath-repro.json' @{
    started = $started.ToString('o'); selectedServer = $selected; closeClicks = $closeClicks; uiEvents = $uiEvents
    decoys = @($decoySpec | ForEach-Object { $_.name }); decoyPids = $decoyPids; windowHostPid = $windowHostPid
    samples = $samples; dialogLog = $dialogLog; logHits = $logHits }
Write-Output 'thirdpath-repro.json published'
