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
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr w, StringBuilder n, int c);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint p);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr w, uint m, IntPtr p1, IntPtr p2);
  static object[] Child(IntPtr w) {
    var r = new List<object>();
    EnumChildWindows(w, (c, v) => { var t = new StringBuilder(512); var n = new StringBuilder(256); GetWindowTextW(c, t, 512); GetClassNameW(c, n, 256); if (t.Length > 0 || n.ToString() == "Button") r.Add(new { cls = n.ToString(), text = t.ToString() }); return r.Count < 10; }, IntPtr.Zero);
    return r.ToArray();
  }
  public static object[] Dialogs() {
    var result = new List<object>();
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); var n = new StringBuilder(256); uint p;
      GetWindowTextW(w, t, 512); GetClassNameW(w, n, 256); GetWindowThreadProcessId(w, out p);
      string cls = n.ToString(); string title = t.ToString();
      if (cls == "#32770" || title.Contains("LockDown") || title.Contains("Authorization"))
        result.Add(new { pid = p, cls = cls, title = title, children = Child(w) });
      return result.Count < 20;
    }, IntPtr.Zero);
    return result.ToArray();
  }
  public static int DismissAuth() {
    int n = 0;
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); GetWindowTextW(w, t, 512);
      if (t.ToString() == "Authorization Error") {
        EnumChildWindows(w, (c, cv) => { var cn = new StringBuilder(256); GetClassNameW(c, cn, 256); var ct = new StringBuilder(64); GetWindowTextW(c, ct, 64); if (cn.ToString() == "Button" && ct.ToString() == "OK") { PostMessageW(c, 0x00F5, IntPtr.Zero, IntPtr.Zero); n++; } return true; }, IntPtr.Zero);
      }
      return true;
    }, IntPtr.Zero);
    return n;
  }
}
'@

function Test-PidAlive([int]$TargetPid) { if (-not $TargetPid) { return $false }; return [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) }

# Build trigger processes from cmd.exe (real self-contained exe; notepad on Win11 is a Store-app stub that exits immediately).
$triggerNames = @('deskpins.exe', 'sidebar.exe', 'msmsgs.exe', 'synergy.exe')
$triggerDir = Join-Path $lab 'triggers'
New-Item -ItemType Directory -Path $triggerDir -Force | Out-Null
foreach ($name in $triggerNames) {
  Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination (Join-Path $triggerDir $name) -Force
}

function Start-Triggers {
  $started = @()
  foreach ($name in $triggerNames) {
    $proc = Start-Process -FilePath (Join-Path $triggerDir $name) -ArgumentList '/k','title trigger' -WindowStyle Minimized -PassThru
    $started += @{ name = $name; pid = $proc.Id }
  }
  Start-Sleep -Seconds 2
  return $started
}

function Stop-Triggers {
  foreach ($name in $triggerNames) { Get-Process -Name ($name -replace '\.exe$','') -ErrorAction SilentlyContinue | Stop-Process -Force }
}

function Run-Phase([string]$Phase, [string]$ExePath, [string]$Arguments, [int]$Seconds) {
  # cleanup
  [void][NW]::DismissAuth()
  Get-Process -Name ExperimentLauncher, Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | Stop-Process -Force
  Get-Process | Where-Object { $_.Name -match '^(Respondus|NpgLab|SecureBrowser|LockDown)' } | Stop-Process -Force
  Stop-Triggers
  Start-Sleep -Seconds 4

  $triggers = Start-Triggers
  $preAlive = @($triggers | ForEach-Object { [int](Test-PidAlive $_.pid) })

  $logFile = Join-Path $lab ('phase-' + $Phase + '.jsonl')
  if (Test-Path $logFile) { Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue }
  if ([string]::IsNullOrWhiteSpace($Arguments)) {
    $launcher = Start-Process -FilePath $ExePath -WindowStyle Hidden -PassThru
  } else {
    $launcher = Start-Process -FilePath $ExePath -ArgumentList $Arguments -WindowStyle Hidden -PassThru
  }

  $samples = @()
  for ($i = 0; $i -lt ($Seconds * 2); $i++) {
    Start-Sleep -Milliseconds 500
    $t = [Math]::Round(($i + 1) * 0.5, 1)
    $entry = @{
      t = $t
      ldb = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count
      triggers = @($triggers | ForEach-Object { [int](Test-PidAlive $_.pid) })
    }
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
  Get-Process | Where-Object { $_.Name -match '^(Respondus|NpgLab|SecureBrowser|LockDown)' } | Stop-Process -Force
  Stop-Triggers
  [void][NW]::DismissAuth()
  Start-Sleep -Seconds 2
  return @{ phase = $Phase; triggers = $triggers; preAlive = $preAlive; launcherPid = $launcher.Id; samples = $samples; events = $events }
}

$baseline = Run-Phase 'baseline-original' 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' '' 45
$variant = Run-Phase 'variant-delayed' (Join-Path $lab 'ExperimentLauncher.exe') '--patch-mode delayed --log C:\NpgLab\phase-variant-delayed.jsonl' 50
@{ baseline = $baseline; variant = $variant } | ConvertTo-Json -Depth 5 -Compress
