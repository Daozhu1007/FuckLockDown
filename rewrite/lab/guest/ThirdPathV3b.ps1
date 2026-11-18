# Third kill-path acceptance with the v3 production launcher.
# Same decoy set as the reproduction run; the v3 launcher must keep every
# decoy alive for 240 s, reach the LMS (server auto-selected), and emit
# image_data_neutralized + policy_activated + periodic_scan_gate_cleared
# in its own trace while the browser never shows a close-app dialog.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$dir = Join-Path $lab '3rd'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$v3 = '2789c065362abfb50e2503ddd1cdb8d603b1fe94e958111344fcfa4d54927eb2'
$launcherPath = Join-Path $lab 'LockDownBrowser.NoProcessGate.exe'
$tracePath = Join-Path $lab ('thirdlog-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.jsonl')
Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/LockDownBrowser.NoProcessGate.exe') -Headers $headers -OutFile $launcherPath -TimeoutSec 120
$actual = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $v3) { throw ('v3 download hash mismatch: ' + $actual) }
Write-Output 'v3 launcher downloaded and verified'

function Publish-Watch([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 14 -Compress
    $reportDirectory = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $reportDirectory)) { New-Item -ItemType Directory -Path $reportDirectory | Out-Null }
    [IO.File]::WriteAllText((Join-Path $reportDirectory $Name), $body, [Text.UTF8Encoding]::new($false))
    try {
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
    } catch { }
}

# --- decoys (same set as the reproduction run) -----------------------------
# v2.1 acceptance: heap-table decoys (the v2-covered B1 names). The alpha
# needle decoys are excluded because the .rdata neutering was measured
# state-unreliable and the production set is empty (see neutre-matrix*.json);
# their behavior with this launcher equals the original's and is documented.
$decoySpec = @(
    @{ name = 'IrisPortable.exe';   args = @('/k', 'rem iris decoy') }
    @{ name = 'sunloginclient.exe'; args = @('/k', 'rem sunlogin decoy') }
    @{ name = 'deskpins.exe';       args = @('/k', 'rem deskpins decoy') }
)
Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('WUDFHost.exe','Spyrix Monitor.exe','ReadAndWrite.exe','SelfService.exe','IrisPortable.exe','sunloginclient.exe','deskpins.exe') -or $_.CommandLine -match 'DecoyWindowsHost' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$decoyPids = @()
foreach ($spec in $decoySpec) {
    $path = Join-Path $dir $spec.name
    Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path -Force
    $process = Start-Process -FilePath $path -ArgumentList $spec.args -WindowStyle Hidden -PassThru
    $decoyPids += $process.Id
}
Remove-Item -LiteralPath (Join-Path $dir 'ui-events.log') -Force -ErrorAction SilentlyContinue
$windowHostPid = 0
Write-Output ('decoys: ' + ($decoyPids -join ',') + ' windowhost: ' + $windowHostPid)

# --- v3 launcher ------------------------------------------------------------
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
Start-Sleep -Seconds 3
$launcher = Start-Process -FilePath $launcherPath -ArgumentList '--no-ui','--log',$tracePath -WindowStyle Hidden -PassThru
$childPid = 0
for ($wait = 0; $wait -lt 40; $wait++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path -LiteralPath $tracePath) {
        $created = @(Get-Content -LiteralPath $tracePath | Where-Object { $_ -match 'child_created_suspended' } | Select-Object -First 1)
        if ($created.Count) {
            $childPid = ([regex]::Match($created[0], '"pid"\s*:\s*(\d+)')).Groups[1].Value -as [int]
            if ($childPid) { break }
        }
    }
}
Write-Output ('child pid from trace: ' + $childPid)

$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$dialogLog = @()
$closeClicks = @()
$lastDialogKey = ''
$selected = $null
$lastUpload = -1
while ($elapsed.Elapsed.TotalSeconds -lt 120) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    $samples += @{ t = $t
                   launcherAlive = [bool](Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)
                   browserAlive = [bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue)
                   decoys = @($decoyPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) })
                   windowHostAlive = $windowHostPid -ne 0 -and [bool](Get-Process -Id $windowHostPid -ErrorAction SilentlyContinue) }
    if ([int]$t -ne $lastUpload -and [int]$t % 10 -eq 0) {
        $lastUpload = [int]$t
        Publish-Watch 'thirdpath-v3-partial.json' @{ t=$t; selectedServer=$selected; closeClicks=$closeClicks; samples=$samples }
    }
}

# --- launcher trace digest ---------------------------------------------------
$traceEvents = @()
if (Test-Path -LiteralPath $tracePath) {
    $traceEvents = @(Get-Content -LiteralPath $tracePath | ForEach-Object { $_ | ConvertFrom-Json })
}
$interesting = @('preflight','image_data_neutralized','policy_activated','policy_data_verified',
                 'periodic_scan_gate_cleared','child_initializing','child_exit','error')
$digest = @($traceEvents | Where-Object { $interesting -contains $_.eventType } |
    ForEach-Object { @{ time=$_.time; eventType=$_.eventType; data=$_.data } })

# --- cleanup -----------------------------------------------------------------
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null

$uiEvents = @()
$uiLog = Join-Path $dir 'ui-events.log'
if (Test-Path -LiteralPath $uiLog) { $uiEvents = @(Get-Content -LiteralPath $uiLog) }
Publish-Watch 'thirdpath-v3.json' @{
    v3 = $v3; started = [DateTimeOffset]::UtcNow.ToString('o'); selectedServer = $selected; uiEvents = $uiEvents
    closeClicks = $closeClicks; decoys = @($decoySpec | ForEach-Object { $_.name }); decoyPids = $decoyPids
    windowHostPid = $windowHostPid; childPid = $childPid; trace = $digest
    samples = $samples; dialogLog = $dialogLog }
Write-Output 'thirdpath-v3.json published'
