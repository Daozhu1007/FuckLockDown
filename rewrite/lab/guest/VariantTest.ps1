[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Stop'
$lab = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $lab 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
foreach ($file in @('LockDownBrowser.NoProcessGate.exe','VerifyVersion.exe','patch-plan.json')) {
    Invoke-WebRequest -UseBasicParsing -Uri ($configuration.endpoint + '/artifact/' + $file) -Headers $headers -OutFile (Join-Path $lab $file) -TimeoutSec 180
}
$check = & (Join-Path $lab 'VerifyVersion.exe') --log 'C:\NpgLab\variant-version-check.jsonl' | Out-String

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
    EnumChildWindows(w, (c, v) => {
      var t = new StringBuilder(512); GetWindowTextW(c, t, 512);
      if (t.Length > 0) r.Add(t.ToString());
      return r.Count < 40;
    }, IntPtr.Zero);
    return r.ToArray();
  }
  public static object[] Snap() {
    var result = new List<object>();
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); var n = new StringBuilder(256); uint p;
      GetWindowTextW(w, t, 512); GetClassNameW(w, n, 256); GetWindowThreadProcessId(w, out p);
      string cls = n.ToString();
      if (t.Length > 0 || cls == "#32770")
        result.Add(new { pid = p, cls = cls, title = t.ToString(), children = Child(w) });
      return result.Count < 60;
    }, IntPtr.Zero);
    return result.ToArray();
  }
}
'@

function Test-PidAlive([int]$TargetPid) {
  if (-not $TargetPid) { return $false }
  return [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)
}

# fixtures (reuse running notepad if the baseline left it alive)
$notepad = Get-Process -Name notepad -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $notepad) { $notepad = Start-Process -FilePath 'notepad.exe' -PassThru }
$sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 3600' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2

$logFile = 'C:\NpgLab\variant-launch.jsonl'
if (Test-Path $logFile) { Remove-Item -LiteralPath $logFile -Force }
$launcher = Start-Process -FilePath (Join-Path $lab 'LockDownBrowser.NoProcessGate.exe') -ArgumentList "--log $logFile" -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 3
$browserPids = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

$timeline = @()
for ($i = 0; $i -lt 16; $i++) {
  Start-Sleep -Seconds 5
  $timeline += @{
    t = ($i + 1) * 5
    launcherAlive = (Test-PidAlive $launcher.Id)
    notepadAlive = (Test-PidAlive $notepad.Id)
    sleeperAlive = (Test-PidAlive $sleeper.Id)
    ldbProcCount = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count
    windows = [NW]::Snap()
  }
}

$launchLog = if (Test-Path $logFile) { Get-Content -LiteralPath $logFile -Raw } else { '(missing)' }
@{
  versionCheck = $check
  launcherPid = $launcher.Id
  browserPids = $browserPids
  notepadPid = $notepad.Id
  sleeperPid = $sleeper.Id
  timeline = $timeline
  launchLog = $launchLog
} | ConvertTo-Json -Depth 6 -Compress
