[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class NW2 {
  public delegate bool CB(IntPtr w, IntPtr v);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB c, IntPtr v);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w, StringBuilder t, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint p);
  public static List<object> Wins() {
    var r = new List<object>();
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); uint p;
      GetWindowTextW(w, t, 512);
      string title = t.ToString();
      if (title.Length > 0 && (title.Contains("LockDown") || title.Contains("Authorization") || title.Contains("Task Manager") || title.Contains("Respondus")))
        { GetWindowThreadProcessId(w, out p); r.Add(new { pid = p, title = title }); }
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@
$wins = [NW2]::Wins()
Write-Output ('windows: ' + ($wins | ConvertTo-Json -Compress -Depth 3))
$procs = Get-Process | Where-Object { $_.Name -match 'Lock|Respondus|Npg|Experiment|Secure|Browser' } | Select-Object Name, Id, Path
Write-Output ('procs: ' + ($procs | ConvertTo-Json -Compress))
# owners of visible interesting windows
$ownerPids = @{}
foreach ($w in $wins) { $ownerPids[[int]$w.pid] = $true }
$owners = foreach ($p in $ownerPids.Keys) {
  $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
  if ($pr) { @{ pid = $p; name = $pr.Name; path = $pr.Path } }
}
Write-Output ('owners: ' + ($owners | ConvertTo-Json -Compress -Depth 3))
