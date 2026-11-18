[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
if (-not $mode) { $mode = $args[0] }
if (-not $mode) { $mode = 'none' }
$logName = 'exp-' + $mode + '.jsonl'
Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/VerifyVersion.exe') -Headers $headers -OutFile (Join-Path $lab 'ExperimentLauncher.exe') -TimeoutSec 180
$downloadHash = (Get-FileHash -LiteralPath (Join-Path $lab 'ExperimentLauncher.exe') -Algorithm SHA256).Hash.ToLowerInvariant()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class NW {
  public delegate bool CB(IntPtr w, IntPtr v);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB c, IntPtr v);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w, CB c, IntPtr v);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w, StringBuilder t, int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr w, StringBuilder t, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint p);
  static object[] Child(IntPtr w) {
    var r = new List<object>();
    EnumChildWindows(w, (c, v) => { var t = new StringBuilder(512); GetWindowTextW(c, t, 512); if (t.Length > 0) r.Add(t.ToString()); return r.Count < 10; }, IntPtr.Zero);
    return r.ToArray();
  }
  public static object[] Dialogs() {
    var result = new List<object>();
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); var n = new StringBuilder(256); uint p;
      GetWindowTextW(w, t, 512); GetClassNameW(w, n, 256); GetWindowThreadProcessId(w, out p);
      string cls = n.ToString(); string title = t.ToString();
      if (cls == "#32770" || title.Contains("LockDown"))
        result.Add(new { pid = p, cls = cls, title = title, children = Child(w) });
      return result.Count < 20;
    }, IntPtr.Zero);
    return result.ToArray();
  }
}
'@

function Test-PidAlive([int]$TargetPid) { if (-not $TargetPid) { return $false }; return [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) }

# Clean up any previous experiment run (browser instances, launchers, dialogs).
Get-Process -Name ExperimentLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$notepad = Get-Process -Name notepad -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $notepad) { $notepad = Start-Process -FilePath 'notepad.exe' -PassThru }
$sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 3600' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2

$logFile = Join-Path $lab $logName
if (Test-Path $logFile) { Remove-Item -LiteralPath $logFile -Force }
$launcher = Start-Process -FilePath (Join-Path $lab 'ExperimentLauncher.exe') -ArgumentList ('--patch-mode ' + $mode + ' --log ' + $logFile) -WindowStyle Hidden -PassThru

$samples = @()
for ($i = 0; $i -lt 130; $i++) {
  Start-Sleep -Milliseconds 500
  $t = [Math]::Round(($i + 1) * 0.5, 1)
  $entry = @{ t = $t; launcher = (Test-PidAlive $launcher.Id); ldb = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count; notepad = (Test-PidAlive $notepad.Id); sleeper = (Test-PidAlive $sleeper.Id) }
  if ($i % 4 -eq 0 -or ($samples.Count -gt 0 -and $samples[-1].ldb -gt 0 -and $entry.ldb -eq 0)) { $entry.dialogs = [NW]::Dialogs() }
  $samples += $entry
  if ($entry.ldb -eq 0 -and $i -gt 10 -and -not $entry.launcher) { break }
}

$events = @()
if (Test-Path $logFile) {
  foreach ($line in Get-Content -LiteralPath $logFile) {
    try { $j = $line | ConvertFrom-Json; $events += @{ time = $j.time; type = $j.eventType } } catch { }
  }
}
@{ mode = $mode; downloadHash = $downloadHash; launcherPid = $launcher.Id; notepadPid = $notepad.Id; sleeperPid = $sleeper.Id; samples = $samples; events = $events } | ConvertTo-Json -Depth 5 -Compress
