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
$windowHost = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $lab 'DecoyWindowsHost.ps1') -WindowStyle Hidden -PassThru
$windowHostPid = 0
for ($wait = 0; $wait -lt 40; $wait++) {
    Start-Sleep -Milliseconds 250
    $pidFile = Join-Path $dir 'windowhost.pid'
    if (Test-Path -LiteralPath $pidFile) { $windowHostPid = [int](Get-Content -LiteralPath $pidFile -Raw); break }
}
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
while ($elapsed.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    [AcceptUI]::DismissUpdateWarning($browserPid) | Out-Null
    if (-not $selected) {
        $click = [AcceptUI]::SelectServer($browserPid)
        Add-Content -LiteralPath (Join-Path $lab 'selectdiag2.txt') -Value ('{0:000.0} pid={1} click={2}' -f $t, $browserPid, [bool]($null -ne $click)) -Encoding utf8
        if ($null -ne $click) { $selected = @{t=$t; result=$click} }
    }
    if ([AcceptUI]::DismissClosePrompt($browserPid)) { $closeClicks += $t }
    $samples += @{ t = $t
                   browserAlive = [bool](Get-Process -Id $browserPid -ErrorAction SilentlyContinue)
                   decoys = @($decoyPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) })
                   windowHostAlive = [bool](Get-Process -Id $windowHostPid -ErrorAction SilentlyContinue) }
    $dialogs = @([AcceptUI]::Dialogs())
    $key = ConvertTo-Json -InputObject $dialogs -Depth 8 -Compress
    if ($key -ne $lastDialogKey) { $dialogLog += @{t=$t; dialogs=$dialogs}; $lastDialogKey = $key }
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

Publish-Watch 'thirdpath-repro.json' @{
    started = $started.ToString('o'); selectedServer = $selected; closeClicks = $closeClicks
    decoys = @($decoySpec | ForEach-Object { $_.name }); decoyPids = $decoyPids; windowHostPid = $windowHostPid
    samples = $samples; dialogLog = $dialogLog; logHits = $logHits }
Write-Output 'thirdpath-repro.json published'
