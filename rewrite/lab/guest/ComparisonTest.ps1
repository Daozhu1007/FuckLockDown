[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'

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

function Run-Phase([string]$Phase, [string]$ExePath, [string]$Arguments, [int]$Seconds) {
  Get-Process -Name ExperimentLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 3

  $taskmgr = Start-Process -FilePath 'taskmgr.exe' -PassThru
  Start-Sleep -Seconds 2

  $logFile = Join-Path $lab ('phase-' + $Phase + '.jsonl')
  if (Test-Path $logFile) { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue }
  $launcher = Start-Process -FilePath $ExePath -ArgumentList $Arguments -WindowStyle Hidden -PassThru

  $samples = @()
  for ($i = 0; $i -lt ($Seconds * 2); $i++) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round(($i + 1) * 0.5, 1)
    $entry = @{ t = $t; ldb = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count; taskmgr = (Test-PidAlive $taskmgr.Id) }
    if ($i % 4 -eq 0) { $entry.dialogs = [NW]::Dialogs() }
    $samples += $entry
  }

  $events = @()
  if (Test-Path $logFile) {
    foreach ($line in Get-Content -LiteralPath $logFile) {
      try { $j = $line | ConvertFrom-Json; $events += @{ time = $j.time; type = $j.eventType } } catch { }
    }
  }
  Get-Process -Name ExperimentLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  return @{ phase = $Phase; taskmgrPid = $taskmgr.Id; launcherPid = $launcher.Id; samples = $samples; events = $events }
}

$variant = Run-Phase 'variant-delayed' (Join-Path $lab 'ExperimentLauncher.exe') '--patch-mode delayed --log C:\NpgLab\phase-variant-delayed.jsonl' 50
$baseline = Run-Phase 'baseline-original' 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' '' 40
@{ variant = $variant; baseline = $baseline } | ConvertTo-Json -Depth 5 -Compress
