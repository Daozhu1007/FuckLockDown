# Control experiments on the UNMODIFIED original, inside the isolated lab guest.
# controlMode 'clean'           : no trigger processes, auto-select first server, watch the full startup path.
# controlMode 'dialog-click'    : 4 trigger processes; when ProcessCloseDlg appears, click
#                                 'Close Application and Continue'; keep watching what the original does next.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
$lab = 'C:\NpgLab'
if (-not (Test-Path -LiteralPath (Join-Path $lab 'config.json'))) { throw 'This test requires the isolated NpgLab guest.' }
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
if ($configuration.endpoint -ne 'http://10.0.2.2:18028') { throw 'Unexpected lab transport; refusing to launch a browser.' }
$headers = @{ 'X-Lab-Token' = $configuration.token }
if (-not (Get-Variable controlMode -ErrorAction SilentlyContinue)) { $controlMode = 'clean' }
if ($controlMode -notin @('clean','dialog-click')) { throw 'Unknown control mode.' }
if (-not (Get-Variable controlSeconds -ErrorAction SilentlyContinue)) { $controlSeconds = 60 }
$runId = [Guid]::NewGuid().ToString('N').Substring(0,12)
$target = 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe'
$expectedTargetHash = '635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582'
$beforeTargetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
if ($beforeTargetHash -ne $expectedTargetHash) { throw 'Wrong original for this control scenario.' }
if (@(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count) {
    throw 'A browser from an earlier run is still active; inspect it before starting this control.'
}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ControlUI {
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
  // Every visible dialog-style window with its full combined child text, any owner process.
  public static object[] Dialogs() {
    var result=new List<object>();
    EnumWindows((window,value)=>{
      if(!IsWindowVisible(window) || Class(window)!="#32770") return true;
      uint owner; GetWindowThreadProcessId(window,out owner);
      var text=new StringBuilder();
      var buttons=new List<string>();
      EnumChildWindows(window,(child,unused)=>{
        string childText=Text(child),name=Class(child);
        if(name=="Button" && childText.Length>0) buttons.Add(childText);
        text.Append(childText); text.Append(" | ");
        return true;
      },IntPtr.Zero);
      result.Add(new {handle=window.ToInt64(),pid=owner,title=Text(window),text=text.ToString(),buttons=buttons.ToArray()});
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
  // Click 'Close Application and Continue' on the process-close dialog owned by pid.
  public static object ClickCloseAndContinue(int pid) {
    object result=null;
    EnumWindows((window,value)=>{
      if(!Owned(window,pid) || !IsWindowVisible(window) || Class(window)!="#32770") return true;
      var combined=new StringBuilder();
      IntPtr accept=IntPtr.Zero; string acceptText=null;
      EnumChildWindows(window,(child,unused)=>{
        string text=Text(child);
        combined.Append(text); combined.Append(" | ");
        if(Class(child)=="Button" && text.Contains("Close Application and Continue")) { accept=child; acceptText=text; }
        return true;
      },IntPtr.Zero);
      string all=combined.ToString();
      if(accept==IntPtr.Zero && !all.Contains("You must close")) return true;
      if(accept!=IntPtr.Zero) { PostMessageW(accept,0xf5,IntPtr.Zero,IntPtr.Zero); result=new {title=Text(window),button=acceptText,handle=window.ToInt64()}; }
      return false;
    },IntPtr.Zero);
    return result;
  }
}
'@
function Publish-Control([string]$Name, [object]$Value) {
    $body = $Value | ConvertTo-Json -Depth 18 -Compress
    $localReports = Join-Path $lab 'reports'
    if (-not (Test-Path -LiteralPath $localReports)) { New-Item -ItemType Directory -Path $localReports | Out-Null }
    [IO.File]::WriteAllText((Join-Path $localReports $Name), $body, [Text.UTF8Encoding]::new($false))
    Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 20 | Out-Null
}
$triggerNames = if ($controlMode -eq 'dialog-click') { @('deskpins.exe','sidebar.exe','msmsgs.exe','synergy.exe') } else { @() }
$directory = Join-Path $lab ('control-' + $runId)
New-Item -ItemType Directory -Path $directory | Out-Null
$triggers = @()
$started = $null
$browserPid = 0
$startedAt = [DateTime]::UtcNow
$samples = @(); $changes = @(); $dialogLog = @()
$selected = $null; $clicked = $null; $last = ''
try {
    foreach ($name in $triggerNames) {
        $path = Join-Path $directory $name
        Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path
        $process = Start-Process -FilePath $path -ArgumentList '/k title ProcessClose acceptance fixture' -WindowStyle Hidden -PassThru
        $triggers += @{name=$name;pid=$process.Id}
    }
    Start-Sleep -Milliseconds 500
    Publish-Control ('control-' + $runId + '-progress.json') @{runId=$runId;mode=$controlMode;state='starting'}
    $started = Start-Process -FilePath $target -WindowStyle Hidden -PassThru
    $browserPid = $started.Id
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    while ($elapsed.Elapsed.TotalSeconds -lt $controlSeconds) {
        Start-Sleep -Milliseconds 250
        $seconds = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
        if (-not $selected) {
            $selection = [ControlUI]::SelectServer($browserPid)
            if ($null -ne $selection) { $selected = @{at=$seconds;result=$selection} }
        }
        $dialogs = @([ControlUI]::Dialogs())
        $dialogKey = ConvertTo-Json -InputObject $dialogs -Depth 10 -Compress
        if ($dialogKey -ne $last) { $dialogLog += @{seconds=$seconds;dialogs=$dialogs}; $last = $dialogKey }
        if ($controlMode -eq 'dialog-click' -and -not $clicked) {
            $click = [ControlUI]::ClickCloseAndContinue($browserPid)
            if ($null -ne $click) { $clicked = @{at=$seconds;result=$click} }
        }
        $windows = @([ControlUI]::Snapshot($browserPid))
        $key = ConvertTo-Json -InputObject $windows -Depth 10 -Compress
        if ($key -ne $last) { $changes += @{seconds=$seconds;windows=$windows} }
        $browserAlive = [bool](Get-Process -Id $browserPid -ErrorAction SilentlyContinue)
        $samples += @{seconds=$seconds;browserAlive=$browserAlive;alive=@($triggers | ForEach-Object {[bool](Get-Process -Id $_.pid -ErrorAction SilentlyContinue)})}
        if (-not $browserAlive) { break }
    }
    $started.Refresh()
    $result = @{
        controlMode=$controlMode;runId=$runId;targetHash=$beforeTargetHash;
        browserPid=$browserPid;startedPid=$started.Id;triggers=$triggers;selectedServer=$selected;
        dialogClick=$clicked;dialogLog=$dialogLog;windowChanges=$changes;samples=$samples;
        browserAliveAtEnd=$samples[-1].browserAlive;
        launcherExitCode=$(if ($started.HasExited) {$started.ExitCode} else {$null})
    }
    Publish-Control ('control-' + $runId + '-result.json') $result
    $result | ConvertTo-Json -Depth 12 -Compress
} finally {
    Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -eq $target -and $_.StartTime.ToUniversalTime() -ge $startedAt.AddSeconds(-1)
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($trigger in $triggers) { Stop-Process -Id $trigger.pid -Force -ErrorAction SilentlyContinue }
    if ($null -ne $started) { $started.Dispose() }
}
