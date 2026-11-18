# End-to-end acceptance for the production launcher (12f8d836...): download via
# /artifact, spawn decoys, start the launcher, auto-select the server, sample
# aliveness and dialogs, publish partials every 10 seconds (hang-proof).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$production = '12f8d8364b3804bf191a07ce2a296256821d61c7dd60ebf67e294b4ea537ff64'
$launcherPath = Join-Path $lab 'LockDownBrowser.NoProcessGate.exe'
Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/LockDownBrowser.NoProcessGate.exe') -Headers $headers -OutFile $launcherPath -TimeoutSec 120
$actual = (Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $production) { throw ('dist download hash mismatch: ' + $actual) }
Write-Output 'dist downloaded and verified'

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
      uint owner; GetWindowThreadProcessId(window,out owner);
      if(owner!=(uint)pid || !IsWindowVisible(window) || Text(window)!="Choose Server") return true;
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
$names = @('IrisPortable.exe','sunloginclient.exe','deskpins.exe')
$triggerPids = @()
foreach ($name in $names) {
    $path = Join-Path $lab ('watch2-' + $name)
    Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path
    $process = Start-Process -FilePath $path -ArgumentList '/k title dist acceptance decoy' -WindowStyle Hidden -PassThru
    $triggerPids += $process.Id
}
$launcher = Start-Process -FilePath $launcherPath -ArgumentList '--no-ui','--log','C:\NpgLab\distlog.jsonl' -WindowStyle Hidden -PassThru
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$dialogLog = @()
$lastDialogKey = ''
$selected = $null
$lastUpload = -1
while ($elapsed.Elapsed.TotalSeconds -lt 120) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    $browser = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue)
    if (-not $selected) {
        [AcceptUI]::DismissUpdateWarning($browser[0].Id) | Out-Null
        $click = [AcceptUI]::SelectServer($browser[0].Id)
        if ($null -ne $click) { $selected = @{t=$t; result=$click} }
    }
    $samples += @{ t = $t
                   launcherAlive = [bool](Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)
                   browserAlive = $browser.Count -gt 0
                   alive = @($triggerPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) }) }
    $dialogs = @([AcceptUI]::Dialogs())
    $key = ConvertTo-Json -InputObject $dialogs -Depth 8 -Compress
    if ($key -ne $lastDialogKey) { $dialogLog += @{t=$t; dialogs=$dialogs}; $lastDialogKey = $key }
    if ([int]$t -ne $lastUpload -and [int]$t % 10 -eq 0) {
        $lastUpload = [int]$t
        Publish-Watch 'dist-acceptance-partial.json' @{ t=$t; selectedServer=$selected; samples=$samples; dialogLog=$dialogLog; production=$production }
    }
}
$result = @{ end=[DateTimeOffset]::UtcNow.ToString('o'); production=$production; selectedServer=$selected;
             samples=$samples; dialogLog=$dialogLog; triggers=$names }
Publish-Watch 'dist-acceptance.json' $result
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
foreach ($triggerPid in $triggerPids) { Stop-Process -Id $triggerPid -Force -ErrorAction SilentlyContinue }
