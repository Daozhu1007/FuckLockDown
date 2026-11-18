[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
$result = @{}

# --- 1. Agent watchdog: relaunch GuestAgent.ps1 when its mutex disappears ---
$watchdogSource = @'
using System;
using System.Diagnostics;
using System.Threading;
public static class NpgWatchdog {
  public static void Main() {
    for (;;) {
      Thread.Sleep(3000);
      try { System.Threading.Mutex.OpenExisting(@"Local\NpgLabGuestAgent"); }
      catch (System.Threading.WaitHandleCannotBeOpenedException) {
        try {
          ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", "-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\\NpgLab\\GuestAgent.ps1");
          psi.WindowStyle = ProcessWindowStyle.Hidden; psi.CreateNoWindow = true; psi.UseShellExecute = false;
          Process.Start(psi);
        } catch {}
      } catch {}
    }
  }
}
'@
$cs = Join-Path $lab 'Watchdog.cs'; $exe = Join-Path $lab 'Watchdog.exe'
Set-Content -LiteralPath $cs -Value $watchdogSource -Encoding UTF8
$compiled = $true
if (-not (Test-Path $exe)) {
  $out = & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /out:$exe /target:winexe $cs 2>&1
  if (-not (Test-Path $exe)) { $compiled = $false; $result.watchdogError = ($out | Out-String) }
}
if ($compiled) {
  Start-Process -FilePath $exe -WindowStyle Hidden
  $result.watchdog = 'started'
}

# --- 2. Window snapshot helper (top-level visible windows incl. child captions) ---
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

# --- 3. Fixtures ---
$notepad = Start-Process -FilePath 'notepad.exe' -PassThru
$sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command Start-Sleep -Seconds 3600' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
$result.fixtures = @{ notepadPid = $notepad.Id; sleeperPid = $sleeper.Id }

# --- 4. Start original browser ---
$ldb = Start-Process -FilePath 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' -PassThru
$result.ldbStartPid = $ldb.Id

# --- 5. Observe ---
$timeline = @()
for ($i = 0; $i -lt 14; $i++) {
  Start-Sleep -Seconds 5
  $timeline += @{
    t = ($i + 1) * 5
    ldbAlive = (Test-PidAlive $ldb.Id)
    notepadAlive = (Test-PidAlive $notepad.Id)
    sleeperAlive = (Test-PidAlive $sleeper.Id)
    ldbProcCount = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count
    windows = [NW]::Snap()
  }
}
$result.timeline = $timeline

# --- 6. Cleanup browser, keep fixtures for later ---
$cleanup = @(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -PassThru })
Start-Sleep -Seconds 3
$result.killed = @($cleanup | ForEach-Object { $_.Id })
$result.ldbAliveAfterKill = (Test-PidAlive $ldb.Id)
$result.fixturesAfterRun = @{ notepadAlive = (Test-PidAlive $notepad.Id); sleeperAlive = (Test-PidAlive $sleeper.Id) }
$result | ConvertTo-Json -Depth 6 -Compress
