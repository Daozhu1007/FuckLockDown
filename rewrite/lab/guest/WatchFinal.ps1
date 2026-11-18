# Watcher for the final production-launcher verification. Runs detached in the
# guest; publishes partial results every 10 seconds so a hung tail cannot lose
# the recorded evidence. The production launcher at C:\NpgLab\LockDownBrowser.NoProcessGate.exe
# was downloaded and hash-verified by the acceptance script before its browser start.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WatchUI {
  public delegate bool Callback(IntPtr window, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr window, Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, StringBuilder text, int length);
  static string Text(IntPtr window) { var t=new StringBuilder(2048); GetWindowTextW(window,t,t.Capacity); return t.ToString(); }
  static string Class(IntPtr window) { var t=new StringBuilder(256); GetClassNameW(window,t,t.Capacity); return t.ToString(); }
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
      result.Add(new {handle=window.ToInt64(),pid=owner,title=Text(window),text=text.ToString(),buttons=buttons.ToArray()});
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
        Invoke-RestMethod -Uri ($configuration.endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
    } catch { }
}
$names = @('deskpins.exe','sidebar.exe','msmsgs.exe','synergy.exe')
$triggerPids = @()
foreach ($name in $names) {
    $path = Join-Path $lab ('watch-' + $name)
    Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination $path
    $process = Start-Process -FilePath $path -ArgumentList '/k title watcher fixture' -WindowStyle Hidden -PassThru
    $triggerPids += $process.Id
}
$launcher = Start-Process -FilePath (Join-Path $lab 'LockDownBrowser.NoProcessGate.exe') -ArgumentList '--no-ui' -WindowStyle Hidden -PassThru
$elapsed = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
$dialogLog = @()
$lastDialogKey = ''
$lastUpload = -1
while ($elapsed.Elapsed.TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round($elapsed.Elapsed.TotalSeconds, 3)
    $browser = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue)
    $samples += @{ t = $t
                   launcherAlive = [bool](Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue)
                   browserAlive = $browser.Count -gt 0
                   browserPids = @($browser | ForEach-Object { $_.Id })
                   alive = @($triggerPids | ForEach-Object { [bool](Get-Process -Id $_ -ErrorAction SilentlyContinue) }) }
    $dialogs = @([WatchUI]::Dialogs())
    $key = ConvertTo-Json -InputObject $dialogs -Depth 10 -Compress
    if ($key -ne $lastDialogKey) { $dialogLog += @{ t = $t; dialogs = $dialogs }; $lastDialogKey = $key }
    if ([int]$t -ne $lastUpload -and [int]$t % 10 -eq 0) {
        $lastUpload = [int]$t
        Publish-Watch 'watch-final-partial.json' @{ t = $t; samples = $samples; dialogLog = $dialogLog; triggers = $names }
    }
}
$result = @{ end = [DateTimeOffset]::UtcNow.ToString('o'); samples = $samples; dialogLog = $dialogLog;
             triggers = $names; triggerPids = $triggerPids; launcherPid = $launcher.Id }
Publish-Watch 'watch-final.json' $result
foreach ($triggerPid in $triggerPids) { Stop-Process -Id $triggerPid -Force -ErrorAction SilentlyContinue }
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Id $launcher.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
