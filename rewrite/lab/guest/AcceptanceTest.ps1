# Runs only in the existing isolated QEMU guest. No exam login is performed.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
$lab = 'C:\NpgLab'
if (-not (Test-Path -LiteralPath (Join-Path $lab 'config.json'))) { throw 'This test requires the isolated NpgLab guest.' }
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
if ($configuration.endpoint -ne 'http://10.0.2.2:18028') { throw 'Unexpected lab transport; refusing to launch a browser.' }
$headers = @{ 'X-Lab-Token' = $configuration.token }
if (-not (Get-Variable acceptMode -ErrorAction SilentlyContinue)) { $acceptMode = 'both' }
if ($acceptMode -notin @('baseline', 'patched', 'both')) { throw 'Unknown acceptance mode.' }
if (-not (Get-Variable acceptSeconds -ErrorAction SilentlyContinue)) { $acceptSeconds = 45 }
if (-not (Get-Variable expectedLauncherHash -ErrorAction SilentlyContinue)) { throw 'Supply the expected final launcher hash.' }
$runId = [Guid]::NewGuid().ToString('N')
$target = 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe'
$launcher = if (Get-Variable acceptLauncherPath -ErrorAction SilentlyContinue) { $acceptLauncherPath } else { Join-Path $lab 'LockDownBrowser.NoProcessGate.exe' }
$expectedTargetHash = '635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582'
$beforeTargetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
if ($beforeTargetHash -ne $expectedTargetHash) { throw 'Wrong original for this acceptance scenario.' }
if (@(Get-Process -Name LockDownBrowser,LockDownBrowser.NoProcessGate -ErrorAction SilentlyContinue).Count) {
    throw 'A browser from an earlier run is still active; inspect it before starting this test.'
}
if ($acceptMode -ne 'baseline') {
    if (-not (Get-Variable acceptSkipDownload -ErrorAction SilentlyContinue) -or -not $acceptSkipDownload) {
        Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/LockDownBrowser.NoProcessGate.exe') -Headers $headers -OutFile $launcher -TimeoutSec 60
    }
    $actualLauncherHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualLauncherHash -ne $expectedLauncherHash.ToLowerInvariant()) { throw 'Received launcher hash does not match the candidate.' }
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class AcceptanceUI {
  public delegate bool Callback(IntPtr window, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr window, Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr window);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr window, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr first, IntPtr second, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr first, StringBuilder second, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr window, uint message, IntPtr first, IntPtr second);
  static string Text(IntPtr window) { var text=new StringBuilder(4096); GetWindowTextW(window,text,text.Capacity); return text.ToString(); }
  static string Class(IntPtr window) { var text=new StringBuilder(256); GetClassNameW(window,text,text.Capacity); return text.ToString(); }
  static bool Owned(IntPtr window, int pid) { uint owner; GetWindowThreadProcessId(window,out owner); return owner==pid; }
  static IntPtr Send(IntPtr window,uint message,IntPtr first,IntPtr second) { IntPtr result; return SendMessageTimeout(window,message,first,second,0x22,100,out result)==IntPtr.Zero?IntPtr.Zero:result; }
  static void SendText(IntPtr window,uint message,IntPtr first,StringBuilder second) { IntPtr result; SendMessageTimeout(window,message,first,second,0x22,100,out result); }
  public static object[] Snapshot(int pid) {
    var result=new List<object>();
    EnumWindows((window,value)=>{
      if((pid>0 && !Owned(window,pid)) || !IsWindowVisible(window)) return true;
      uint owner; GetWindowThreadProcessId(window,out owner);
      var children=new List<object>();
      EnumChildWindows(window,(child,unused)=>{
        string text=Text(child),name=Class(child);
        if(text.Length>0 || name=="Button") children.Add(new {id=GetDlgCtrlID(child),cls=name,text=text});
        return true;
      },IntPtr.Zero);
      result.Add(new {handle=window.ToInt64(),pid=owner,title=Text(window),cls=Class(window),children=children.ToArray()});
      return true;
    },IntPtr.Zero);
    return result.ToArray();
  }
  public static object SelectServer(int pid) {
    object result=null;
    EnumWindows((window,value)=>{
      if(!Owned(window,pid) || !IsWindowVisible(window) || Text(window)!="Choose Server") return true;
      IntPtr combo=GetDlgItem(window,1013);
      int count=Send(combo,0x146,IntPtr.Zero,IntPtr.Zero).ToInt32();
      if(count<1 || count>32) return true;
      var entries=new List<string>();
      for(int i=0;i<count;i++) { var text=new StringBuilder(2048); SendText(combo,0x148,new IntPtr(i),text); entries.Add(text.ToString()); }
      if(count>0) {
        Send(combo,0x14e,IntPtr.Zero,IntPtr.Zero);
        PostMessageW(window,0x111,new IntPtr((1<<16)|1013),combo);
        PostMessageW(GetDlgItem(window,1),0xf5,IntPtr.Zero,IntPtr.Zero);
      }
      result=new {entries=entries.ToArray(),selected=count>0?0:-1};
      return false;
    },IntPtr.Zero);
    return result;
  }
  public static object AcknowledgeStartupNotice(int pid) {
    object result=null;
    EnumWindows((window,value)=>{
      if(!Owned(window,pid) || !IsWindowVisible(window) || Class(window)!="#32770") return true;
      var text=new StringBuilder();
      EnumChildWindows(window,(child,unused)=>{text.Append(Text(child));return true;},IntPtr.Zero);
      if(!text.ToString().Contains("Warning: Windows Update is active and might interfere")) return true;
      IntPtr button=GetDlgItem(window,1);
      if(button!=IntPtr.Zero) {
        PostMessageW(button,0xf5,IntPtr.Zero,IntPtr.Zero);
        result=new {kind="windows-update-warning",handle=window.ToInt64()};
      }
      return false;
    },IntPtr.Zero);
    return result;
  }
}
'@
function Publish-Acceptance([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 18 -Compress
    $localReports = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $localReports)) { New-Item -ItemType Directory -Path $localReports | Out-Null }
    [IO.File]::WriteAllText((Join-Path $localReports $Name), $body, [Text.UTF8Encoding]::new($false))
    Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
}
function Save-AcceptanceScreen([string]$Phase) {
    # Capture through host QMP; guest GDI can block on a locked desktop.
    return $null
}
function Read-LauncherEvents([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return @()
}
function Run-AcceptancePhase([string]$Phase) {
    $triggerNames = if (Get-Variable acceptTriggerNames -ErrorAction SilentlyContinue) { @($acceptTriggerNames) } else { @('deskpins.exe','sidebar.exe','msmsgs.exe','synergy.exe') }
    $directory = Join-Path $lab ('acceptance-' + $runId + '-' + $Phase)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $triggers = @()
    $started = $null
    $browserPid = 0
    $startedAt = [DateTime]::UtcNow
    $trace = Join-Path $directory 'launcher.jsonl'
    $result = $null
    try {
        foreach ($name in $triggerNames) {
            $path = Join-Path $directory $name
            Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path
            $process = Start-Process -FilePath $path -ArgumentList '/k title ProcessClose acceptance fixture' -WindowStyle Hidden -PassThru
            $triggers += @{name=$name;pid=$process.Id}
        }
        Start-Sleep -Milliseconds 500
        foreach ($trigger in $triggers) {
            if (-not (Get-Process -Id $trigger.pid -ErrorAction SilentlyContinue)) { throw ('Trigger did not remain alive: ' + $trigger.name) }
        }
        Publish-Acceptance ('acceptance-' + $runId + '-progress.json') @{runId=$runId;phase=$Phase;state='starting';launcherHash=$expectedLauncherHash}
        if ($Phase -eq 'baseline') {
            $started = Start-Process -FilePath $target -WindowStyle Hidden -PassThru
            $browserPid = $started.Id
        } else {
            $started = Start-Process -FilePath $launcher -ArgumentList @('--no-ui','--log',('"' + $trace + '"')) -WindowStyle Hidden -PassThru
        }
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $samples = @()
        $changes = @()
        $selected = $null
        $last = ''
        $sawProcessPrompt = $false
        $acknowledgedNotices = @()
        $authorizationErrors = @()
        while ($elapsed.Elapsed.TotalSeconds -lt $acceptSeconds) {
            Start-Sleep -Milliseconds 250
            if (-not $browserPid -and $Phase -eq 'patched') {
                $created = @(Read-LauncherEvents $trace | Where-Object eventType -EQ 'child_created_suspended' | Select-Object -First 1)
                if ($created.Count) { $browserPid = [int]$created[0].data.pid }
            }
            $seconds = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
            if ($browserPid) {
                $notice = [AcceptanceUI]::AcknowledgeStartupNotice($browserPid)
                if ($null -ne $notice) { $acknowledgedNotices += @{seconds=$seconds;notice=$notice} }
                if (-not $selected) {
                    $selection = [AcceptanceUI]::SelectServer($browserPid)
                    if ($null -ne $selection) { $selected = @{at=$seconds;result=$selection} }
                }
                $windows = @([AcceptanceUI]::Snapshot($browserPid))
            } else { $windows = @() }
            $key = ConvertTo-Json -InputObject $windows -Depth 10 -Compress
            if ($key -ne $last) { $changes += @{seconds=$seconds;windows=$windows}; $last=$key }
            if ($key -match 'You must close|Close Application and Continue') { $sawProcessPrompt = $true }
            $foreignErrors = @([AcceptanceUI]::Snapshot(-1) | Where-Object {
                $_.title -eq 'Authorization Error' -or
                @($_.children | Where-Object {$_.text -match 'LockDown Browser cannot run because it is corrupted'}).Count -gt 0
            })
            if ($foreignErrors.Count -and $authorizationErrors.Count -eq 0) {
                $authorizationErrors += @{seconds=$seconds;windows=$foreignErrors}
            }
            $browserAlive = $browserPid -gt 0 -and [bool](Get-Process -Id $browserPid -ErrorAction SilentlyContinue)
            $samples += @{seconds=$seconds;browserAlive=$browserAlive;alive=@($triggers | ForEach-Object {[bool](Get-Process -Id $_.pid -ErrorAction SilentlyContinue)})}
            $started.Refresh()
            if ($started.HasExited -and ($Phase -eq 'patched' -or -not $samples[-1].browserAlive)) { break }
        }
        $events = @(Read-LauncherEvents $trace)
        $started.Refresh()
        $patchCount = @($events | Where-Object eventType -EQ 'patch_verified').Count
        $allTriggersAlive = @($samples | Where-Object {$_.alive -contains $false}).Count -eq 0
        $result = @{
            phase=$Phase;runId=$runId;targetHash=$beforeTargetHash;launcherHash=$expectedLauncherHash;
            browserPid=$browserPid;startedPid=$started.Id;launcherExited=$started.HasExited;
            launcherExitCode=$(if ($started.HasExited) {$started.ExitCode} else {$null});
            triggers=$triggers;selectedServer=$selected;windowChanges=$changes;samples=$samples;events=$events;
            acknowledgedNotices=$acknowledgedNotices;
            authorizationErrors=$authorizationErrors;
            processPromptObserved=$sawProcessPrompt;allTriggersAlive=$allTriggersAlive;verifiedPatchCount=$patchCount;
            browserAliveAtEnd=$samples[-1].browserAlive;
            remainingDialogs=@($windows | Where-Object cls -EQ '#32770');
            screenReceipt=(Save-AcceptanceScreen $Phase)
        }
        Publish-Acceptance ('acceptance-' + $runId + '-' + $Phase + '.json') $result
        return $result
    } finally {
        # The guest guard above and original-image/start-time checks bound cleanup to this run.
        Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -eq $target -and $_.StartTime.ToUniversalTime() -ge $startedAt.AddSeconds(-1)
        } | Stop-Process -Force
        foreach ($trigger in $triggers) { Stop-Process -Id $trigger.pid -Force -ErrorAction SilentlyContinue }
        if ($null -ne $started) {
            $started.Refresh()
            if (-not $started.HasExited) { $started.WaitForExit(5000) | Out-Null; $started.Refresh() }
            if (-not $started.HasExited -and $Phase -eq 'patched') { Stop-Process -Id $started.Id -Force }
            $started.Dispose()
        }
    }
}
$phases = @()
if ($acceptMode -in @('baseline','both')) { $phases += Run-AcceptancePhase 'baseline' }
if ($acceptMode -in @('patched','both')) {
    Start-Sleep -Seconds 2
    $phases += Run-AcceptancePhase 'patched'
}
$afterTargetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
$summary = @{
    runId=$runId;mode=$acceptMode;targetUnchanged=($beforeTargetHash -eq $afterTargetHash);
    phases=@($phases | ForEach-Object {@{phase=$_.phase;triggerCount=$_.triggers.Count;selectedServer=$_.selectedServer;processPromptObserved=$_.processPromptObserved;allTriggersAlive=$_.allTriggersAlive;verifiedPatchCount=$_.verifiedPatchCount;browserAliveAtEnd=$_.browserAliveAtEnd;launcherExitCode=$_.launcherExitCode;remainingDialogs=$_.remainingDialogs;screenReceipt=$_.screenReceipt}})
}
$baseline = @($phases | Where-Object phase -EQ 'baseline')
$patched = @($phases | Where-Object phase -EQ 'patched')
$summary.passed = $acceptMode -eq 'both' -and $summary.targetUnchanged -and
    $baseline.Count -eq 1 -and $baseline[0].processPromptObserved -and
    $patched.Count -eq 1 -and -not $patched[0].processPromptObserved -and
    $patched[0].triggers.Count -eq 4 -and $patched[0].allTriggersAlive -and
    $patched[0].verifiedPatchCount -eq 15 -and $patched[0].browserAliveAtEnd -and
    @($patched[0].authorizationErrors).Count -eq 0 -and
    $null -ne $patched[0].selectedServer -and @($patched[0].remainingDialogs).Count -eq 0
Publish-Acceptance ('acceptance-' + $runId + '-summary.json') $summary
$summary | ConvertTo-Json -Depth 12 -Compress
