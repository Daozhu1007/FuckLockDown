$ErrorActionPreference = 'Stop'
$created = $false
$agentMutex = New-Object System.Threading.Mutex($true, 'Local\NpgLabGuestAgent', [ref]$created)
if (-not $created) { exit 0 }
$labDirectory = 'C:\NpgLab'
$configuration = Get-Content -LiteralPath (Join-Path $labDirectory 'config.json') -Raw | ConvertFrom-Json
$headers = @{ 'X-Lab-Token' = $configuration.token }
$endpoint = $configuration.endpoint
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class NpgWindows {
  public delegate bool Callback(IntPtr window, IntPtr value);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr value);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window,StringBuilder text,int count);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr window,StringBuilder text,int count);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
  public static List<object> Snapshot() {
    var result=new List<object>();
    EnumWindows((window,value)=>{
      if(!IsWindowVisible(window)) return true;
      var title=new StringBuilder(2048); var name=new StringBuilder(256); uint process;
      GetWindowTextW(window,title,title.Capacity); GetClassNameW(window,name,name.Capacity); GetWindowThreadProcessId(window,out process);
      if(title.Length>0) result.Add(new {handle=window.ToInt64(),pid=process,title=title.ToString(),windowClass=name.ToString()});
      return result.Count<100;
    },IntPtr.Zero);
    return result;
  }
}

public sealed class NpgCaptureResult {
  public int ExitCode = -1;
  public int ProcessId;
  public bool TimedOut;
  public bool ExecutionTimedOut;
  public bool OutputIncomplete;
  public bool OutputTruncated;
  public string Stdout = "";
  public string Stderr = "";
  public string CleanupError = "";
}

public static class NpgProcessCapture {
  private const int OutputLimit = 131072;
  private const int OutputDrainMilliseconds = 1000;

  // These handlers run entirely in managed code. PowerShell scriptblock event
  // handlers can fail on reader threads that do not have a PowerShell runspace.
  private sealed class OutputBuffer {
    private readonly object gate = new object();
    private readonly StringBuilder text = new StringBuilder();
    private bool eof, frozen, truncated;
    internal void Receive(object sender, DataReceivedEventArgs data) {
      lock (gate) {
        if (frozen) return;
        if (data.Data == null) { eof = true; return; }
        string value = data.Data + Environment.NewLine;
        int available = OutputLimit - text.Length;
        if (value.Length > available) truncated = true;
        if (available > 0) text.Append(value, 0, Math.Min(value.Length, available));
      }
    }
    internal bool Ended { get { lock (gate) return eof; } }
    internal string Freeze(out bool incomplete, out bool clipped) {
      lock (gate) {
        frozen = true;
        incomplete = !eof;
        clipped = truncated;
        return text.ToString();
      }
    }
  }

  private static void AddCleanupError(NpgCaptureResult result, string message) {
    if (result.CleanupError.Length > 0) result.CleanupError += "; ";
    result.CleanupError += message;
  }

  private static void ReleaseWithoutBlocking(Process process) {
    // Dispose/Close must not become another pipe-drain wait on runtimes that
    // still have a pending inherited-pipe read. The agent never joins this work.
    ThreadPool.QueueUserWorkItem(value => {
      try { ((Process)value).Dispose(); } catch (Exception) { }
    }, process);
  }

  private static void StopOwnedTree(Process child, NpgCaptureResult result) {
    // Keep the original Process handle open throughout cleanup. Never enumerate
    // processes by name or send taskkill an already-exited process's PID.
    if (child.HasExited) return;
    Process killer = null;
    try {
      ProcessStartInfo start = new ProcessStartInfo();
      start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe");
      start.Arguments = "/PID " + child.Id + " /T /F";
      start.UseShellExecute = false;
      start.CreateNoWindow = true;
      start.RedirectStandardOutput = true;
      start.RedirectStandardError = true;
      killer = new Process();
      killer.StartInfo = start;
      DataReceivedEventHandler discard = (sender, data) => { };
      killer.OutputDataReceived += discard;
      killer.ErrorDataReceived += discard;
      if (!killer.Start()) throw new InvalidOperationException("Cannot start taskkill for this command");
      killer.BeginOutputReadLine();
      killer.BeginErrorReadLine();
      if (!killer.WaitForExit(2000)) {
        try { killer.Kill(); } catch (InvalidOperationException) { } catch (Win32Exception) { }
        killer.WaitForExit(500);
        AddCleanupError(result, "taskkill exceeded its 2000 millisecond cleanup limit");
      }
    } catch (Exception error) {
      AddCleanupError(result, "Tree cleanup: " + error.GetType().Name + ": " + error.Message);
    } finally {
      if (killer != null) ReleaseWithoutBlocking(killer);
    }
    if (!child.HasExited) {
      try { child.Kill(); }
      catch (InvalidOperationException) { }
      catch (Win32Exception error) { AddCleanupError(result, "Child cleanup: " + error.Message); }
    }
    if (!child.WaitForExit(2000))
      AddCleanupError(result, "The command child could not be confirmed terminated within 2000 milliseconds");
  }

  public static NpgCaptureResult Run(ProcessStartInfo start, int timeoutMilliseconds) {
    if (timeoutMilliseconds < 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
    if (start.UseShellExecute || !start.RedirectStandardOutput || !start.RedirectStandardError)
      throw new ArgumentException("Capture requires direct execution with both output streams redirected");
    NpgCaptureResult result = new NpgCaptureResult();
    OutputBuffer stdout = new OutputBuffer(), stderr = new OutputBuffer();
    Process child = new Process();
    child.StartInfo = start;
    DataReceivedEventHandler outputHandler = stdout.Receive, errorHandler = stderr.Receive;
    child.OutputDataReceived += outputHandler;
    child.ErrorDataReceived += errorHandler;
    bool started = false, completed = false;
    try {
      if (!child.Start()) throw new InvalidOperationException("Cannot start the command child");
      started = true;
      result.ProcessId = child.Id;
      // Acquire and retain the handle before checking exit state or invoking
      // taskkill, so this captured PID continues to identify our own process.
      IntPtr ownedHandle = child.Handle;
      child.BeginOutputReadLine();
      child.BeginErrorReadLine();
      completed = child.WaitForExit(timeoutMilliseconds);
      result.ExecutionTimedOut = !completed;
      if (!completed) StopOwnedTree(child, result);
      if (child.HasExited) result.ExitCode = child.ExitCode;

      // A descendant can retain stdout/stderr after its parent has exited.
      // Never call parameterless WaitForExit, ReadToEnd, or Task.Result here.
      Stopwatch drain = Stopwatch.StartNew();
      while ((!stdout.Ended || !stderr.Ended) && drain.ElapsedMilliseconds < OutputDrainMilliseconds)
        Thread.Sleep(10);
      bool stdoutIncomplete, stderrIncomplete, stdoutTruncated, stderrTruncated;
      result.Stdout = stdout.Freeze(out stdoutIncomplete, out stdoutTruncated);
      result.Stderr = stderr.Freeze(out stderrIncomplete, out stderrTruncated);
      result.OutputIncomplete = stdoutIncomplete || stderrIncomplete;
      result.OutputTruncated = stdoutTruncated || stderrTruncated;
      result.TimedOut = result.ExecutionTimedOut || result.OutputIncomplete;
      return result;
    } finally {
      if (started && !completed) {
        try { if (!child.HasExited) StopOwnedTree(child, result); }
        catch (Exception error) { AddCleanupError(result, "Final cleanup: " + error.Message); }
      }
      child.OutputDataReceived -= outputHandler;
      child.ErrorDataReceived -= errorHandler;
      try { child.CancelOutputRead(); } catch (InvalidOperationException) { }
      try { child.CancelErrorRead(); } catch (InvalidOperationException) { }
      ReleaseWithoutBlocking(child);
    }
  }
}
'@
function Send-LabResult([string]$Name, [object]$Value) {
    if ($Name -notmatch '^[A-Za-z0-9_.-]{1,100}$') { throw 'Invalid lab result filename.' }
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $reportDirectory = Join-Path $labDirectory 'reports'
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $reportPath = Join-Path $reportDirectory $Name
    $pendingPath = $reportPath + '.pending-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($pendingPath, $json, [Text.UTF8Encoding]::new($false))
    # [IO.File]::Replace with a PowerShell $null backup argument marshals to an
    # empty string, which .NET rejects with "The path is not of a legal form".
    try { [IO.File]::Replace($pendingPath, $reportPath, [NullString]::Value) }
    catch { [IO.File]::Delete($reportPath); [IO.File]::Move($pendingPath, $reportPath) }
    Invoke-RestMethod -Uri ($endpoint + '/upload/' + $Name) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 15 | Out-Null
}
try {
    # Self-heal the autostart registration so future logons always start this
    # exact fixed agent instead of any stale variant left in the guest.
    New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NpgLabAgent' -Value ('powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $PSCommandPath) -PropertyType String -Force | Out-Null
    while (-not (Test-Path -LiteralPath (Join-Path $labDirectory 'stop.flag'))) {
        try {
            $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            $processNames = @(Get-Process | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object)
            Send-LabResult 'heartbeat.json' @{ time=[DateTimeOffset]::UtcNow.ToString('o'); user=[Environment]::UserName; admin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); windows=[NpgWindows]::Snapshot(); processes=$processNames }
        } catch {
            # A failed heartbeat must never block command polling; it also must
            # not push the outer catch past /command for the whole iteration.
            Add-Content -LiteralPath (Join-Path $labDirectory 'agent.log') -Value ('heartbeat: ' + $_.Exception.Message) -Encoding UTF8
        }
        try {
            $command = Invoke-RestMethod -Uri ($endpoint + '/command') -Headers $headers -TimeoutSec 10
            if ($command -and $command.id) {
                Send-LabResult ('started-' + $command.id + '.json') @{id=$command.id; time=[DateTimeOffset]::UtcNow.ToString('o')}
                $startInfo = New-Object Diagnostics.ProcessStartInfo
                $startInfo.FileName = 'powershell.exe'
                $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $command.encoded
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
                $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
                $timeoutMilliseconds = [long]$command.timeout * 1000
                if ($timeoutMilliseconds -lt 0 -or $timeoutMilliseconds -gt [int]::MaxValue) { throw 'Command timeout is outside the supported millisecond range.' }
                $capture = [NpgProcessCapture]::Run($startInfo, [int]$timeoutMilliseconds)
                Send-LabResult ('reply-' + $command.id + '.json') @{id=$command.id; time=[DateTimeOffset]::UtcNow.ToString('o'); exit=$capture.ExitCode; timeout=$capture.TimedOut; stdout=$capture.Stdout; stderr=$capture.Stderr; outputIncomplete=$capture.OutputIncomplete; outputTruncated=$capture.OutputTruncated; executionTimeout=$capture.ExecutionTimedOut; cleanupError=$capture.CleanupError; childPid=$capture.ProcessId}
            }
        } catch {
            Add-Content -LiteralPath (Join-Path $labDirectory 'agent.log') -Value ($_.Exception.Message) -Encoding UTF8
        }
        Start-Sleep -Seconds 2
    }
} finally {
    $agentMutex.ReleaseMutex()
    $agentMutex.Dispose()
}
