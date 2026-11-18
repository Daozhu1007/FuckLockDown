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
$v3 = '4308bac9830116f8523ae06d6d751b3c6d0cbee25fa1b9687ccbbb791b92d6ea'
$launcherPath = Join-Path $lab 'LockDownBrowser.NoProcessGate.exe'
$tracePath = Join-Path $lab 'thirdlog-v3.jsonl'
Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/LockDownBrowser.NoProcessGate.exe') -Headers $headers -OutFile $launcherPath -TimeoutSec 120
$actual = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $v3) { throw ('v3 download hash mismatch: ' + $actual) }
Write-Output 'v3 launcher downloaded and verified'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class AcceptUI {
  public delegate bool Callback(IntPtr window, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr window, Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr window, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr first, IntPtr second, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr window, uint message, IntPtr first, IntPtr second);
  static string Text(IntPtr window) { var t=new StringBuilder(2048); GetWindowTextW(window,t,t.Capacity); return t.ToString(); }
  static string Class(IntPtr window) { var t=new StringBuilder(256); GetClassNameW(window,t,t.Capacity); return t.ToString(); }
  static IntPtr Send(IntPtr window,uint message,IntPtr first,IntPtr second) { IntPtr result; return SendMessageTimeout(window,message,first,second,0x22,100,out result)==IntPtr.Zero?IntPtr.Zero:result; }
  public static object SelectServer(int pid) {
    object result=null;
    EnumWindows((window,value)=>{
      if(!IsWindowVisible(window) || Text(window)!="Choose Server") return true;
      IntPtr combo=GetDlgItem(window,1013);
      int count=Send(combo,0x146,IntPtr.Zero,IntPtr.Zero).ToInt32();
      if(count<1 || count>32) return true;
      var entries=new List<string>();
      for(int i=0;i<count;i++){ var text=new StringBuilder(2048); IntPtr r; SendMessageTimeout(combo,0x148,new IntPtr(i),text,0x22,100,out r); entries.Add(text.ToString()); }
      Send(combo,0x14e,IntPtr.Zero,IntPtr.Zero);
      PostMessageW(window,0x111,new IntPtr((1<<16)|1013),combo);
      PostMessageW(GetDlgItem(window,1),0xf5,IntPtr.Zero,IntPtr.Zero);
      result=new {entries=entries.ToArray(),selected=0};
      return false;
    },IntPtr.Zero);
    return result;
  }
  public static bool DismissUpdateWarning(int pid) {
    bool done=false;
    EnumWindows((window,value)=>{
      uint owner; GetWindowThreadProcessId(window,out owner);
      if(owner!=(uint)pid || !IsWindowVisible(window)) return true;
      var text=new StringBuilder();
      EnumChildWindows(window,(child,unused)=>{text.Append(Text(child));text.Append(" | ");return true;},IntPtr.Zero);
      if(text.ToString().IndexOf("Windows Update is active")<0) return true;
      IntPtr ok=GetDlgItem(window,1);
      if(ok!=IntPtr.Zero) PostMessageW(ok,0xf5,IntPtr.Zero,IntPtr.Zero);
      done=true;
      return false;
    },IntPtr.Zero);
    return done;
  }
  public static bool DismissClosePrompt(int pid) {
    bool done=false;
    EnumWindows((window,value)=>{
      uint owner; GetWindowThreadProcessId(window,out owner);
      if(owner!=(uint)pid || !IsWindowVisible(window) || Class(window)!="#32770") return true;
      var text=new StringBuilder();
      EnumChildWindows(window,(child,unused)=>{text.Append(Text(child));text.Append(" | ");return true;},IntPtr.Zero);
      if(text.ToString().IndexOf("Close Application and Continue")<0) return true;
      IntPtr ok=GetDlgItem(window,1);
      if(ok!=IntPtr.Zero) PostMessageW(ok,0xf5,IntPtr.Zero,IntPtr.Zero);
      done=true;
      return false;
    },IntPtr.Zero);
    return done;
  }
  public static object[] Dialogs() {
    var result=new List<object>();
    EnumWindows((window,value)=>{
      if(!IsWindowVisible(window) || Class(window)!="#32770") return true;
      uint owner; GetWindowThreadProcessId(window,out owner);
      var text=new StringBuilder(); var buttons=new List<string>();
      EnumChildWindows(window,(child,unused)=>{
        string s=Text(child), name=Class(child);
        if(name=="Button" && s.Length>0) buttons.Add(s);
        text.Append(s); text.Append(" | ");
        return true;
      },IntPtr.Zero);
      result.Add(new {pid=owner,title=Text(window),text=text.ToString(),buttons=buttons.ToArray()});
      return true;
    },IntPtr.Zero);
    return result.ToArray();
  }
}
'@
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
$windowHost = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'DecoyWindowsHost.ps1') -WindowStyle Hidden -PassThru
$windowHostPid = 0
for ($wait = 0; $wait -lt 40; $wait++) {
    Start-Sleep -Milliseconds 250
    $pidFile = Join-Path $dir 'windowhost.pid'
    if (Test-Path -LiteralPath $pidFile) { $windowHostPid = [int](Get-Content -LiteralPath $pidFile -Raw); break }
}
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
while ($elapsed.Elapsed.TotalSeconds -lt 240) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    if ($childPid) {
        [AcceptUI]::DismissUpdateWarning($childPid) | Out-Null
        if (-not $selected) {
            $click = [AcceptUI]::SelectServer($childPid)
            if ($null -ne $click) { $selected = @{t=$t; result=$click} }
        }
        if ([AcceptUI]::DismissClosePrompt($childPid)) { $closeClicks += $t }
    }
    $samples += @{ t = $t
                   launcherAlive = [bool](Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)
                   browserAlive = [bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue)
                   decoys = @($decoyPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) })
                   windowHostAlive = [bool](Get-Process -Id $windowHostPid -ErrorAction SilentlyContinue) }
    $dialogs = @([AcceptUI]::Dialogs())
    $key = ConvertTo-Json -InputObject $dialogs -Depth 8 -Compress
    if ($key -ne $lastDialogKey) { $dialogLog += @{t=$t; dialogs=$dialogs}; $lastDialogKey = $key }
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
Get-Process -Id $childPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($decoyPid in $decoyPids) { Stop-Process -Id $decoyPid -Force -ErrorAction SilentlyContinue }
if ($windowHostPid) { Stop-Process -Id $windowHostPid -Force -ErrorAction SilentlyContinue }
& sc.exe delete EFRService | Out-Null

Publish-Watch 'thirdpath-v3.json' @{
    v3 = $v3; started = [DateTimeOffset]::UtcNow.ToString('o'); selectedServer = $selected
    closeClicks = $closeClicks; decoys = @($decoySpec | ForEach-Object { $_.name }); decoyPids = $decoyPids
    windowHostPid = $windowHostPid; childPid = $childPid; trace = $digest
    samples = $samples; dialogLog = $dialogLog }
Write-Output 'thirdpath-v3.json published'
