[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class NW3 {
  public delegate bool CB(IntPtr w, IntPtr v);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB c, IntPtr v);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w, CB c, IntPtr v);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w, StringBuilder t, int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr w, StringBuilder n, int c);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w, out uint p);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr w, uint m, IntPtr p1, IntPtr p2);
  public static List<object> Find(string needle) {
    var r = new List<object>();
    EnumWindows((w, v) => {
      if (!IsWindowVisible(w)) return true;
      var t = new StringBuilder(512); GetWindowTextW(w, t, 512);
      if (t.ToString().Contains(needle)) { uint p; GetWindowThreadProcessId(w, out p); r.Add(new { hwnd = w, pid = p, title = t.ToString() }); }
      return true;
    }, IntPtr.Zero);
    return r;
  }
  public static List<object> Kids(IntPtr w) {
    var r = new List<object>();
    EnumChildWindows(w, (c, v) => {
      var t = new StringBuilder(256); var n = new StringBuilder(256);
      GetWindowTextW(c, t, 256); GetClassNameW(c, n, 256);
      r.Add(new { hwnd = c, cls = n.ToString(), text = t.ToString() });
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@
Add-Type -Name U3 -Namespace W32 -MemberDefinition '
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr w, uint m, IntPtr p1, IntPtr p2);'

Write-Output ('trigger files: ' + ((Get-ChildItem 'C:\NpgLab\triggers' | Select-Object Name, Length | ConvertTo-Json -Compress)))

# 1) dismiss stuck csrss "Authorization Error" dialog
$dlg = [NW3]::Find('Authorization Error')
foreach ($d in $dlg) {
  $kids = [NW3]::Kids($d.hwnd)
  Write-Output ('dlg children: ' + ($kids | ConvertTo-Json -Compress -Depth 3))
  if ($kids.Count -gt 0) {
    $ok = $kids | Where-Object { $_.cls -eq 'Button' } | Select-Object -First 1
    if ($ok) { [void][NW3]::PostMessageW($ok.hwnd, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); Write-Output 'clicked BM_CLICK on button' }
  } else {
    [void][NW3]::PostMessageW($d.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); Write-Output 'sent WM_CLOSE to window'
  }
}

# 2) kill leftover Taskmgr
Get-Process -Name Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Output 'taskmgr killed'

# 3) start triggers and check survival without any LDB
$names = @('deskpins.exe','sidebar.exe','msmsgs.exe','synergy.exe')
$started = @{}
foreach ($n in $names) {
  $p = Start-Process -FilePath ("C:\NpgLab\triggers\" + $n) -PassThru
  $started[$n] = $p.Id
}
Start-Sleep -Seconds 5
foreach ($n in $names) {
  $alive = [bool](Get-Process -Id $started[$n] -ErrorAction SilentlyContinue)
  Write-Output ("trigger {0} pid={1} alive={2}" -f $n, $started[$n], $alive)
}
$wins = [NW3]::Find('Notepad')
Write-Output ('notepad-titled windows: ' + ($wins | ConvertTo-Json -Compress -Depth 3))
foreach ($n in $names) { Get-Process -Id $started[$n] -ErrorAction SilentlyContinue | Stop-Process -Force }
