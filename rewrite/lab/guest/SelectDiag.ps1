# Diagnose why the detached SelectServer never fires: log each attempt's
# intermediate results (window found, combo handle, item count) to a file.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$lab = 'C:\NpgLab'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DiagUI {
  public delegate bool CB(IntPtr w, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr w, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr first, IntPtr second, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr window, uint message, IntPtr first, IntPtr second);
  static string Text(IntPtr w) { var t=new StringBuilder(2048); GetWindowTextW(w,t,t.Capacity); return t.ToString(); }
  static IntPtr Send(IntPtr w,uint m,IntPtr a,IntPtr b) { IntPtr r; return SendMessageTimeout(w,m,a,b,0x22,100,out r)==IntPtr.Zero?IntPtr.Zero:r; }
  public static string Attempt() {
    var o = new StringBuilder();
    IntPtr found = IntPtr.Zero; int visible = 0; int total = 0;
    EnumWindows((w,p)=>{
      total++;
      if(!IsWindowVisible(w)) return true;
      visible++;
      if(Text(w)=="Choose Server"){ found=w; return false; }
      return true;
    },IntPtr.Zero);
    o.Append("total=").Append(total).Append(" visible=").Append(visible);
    if(found==IntPtr.Zero){ o.Append(" chooseServer=none"); return o.ToString(); }
    o.Append(" chooseServer=").Append(found);
    IntPtr combo=GetDlgItem(found,1013);
    o.Append(" combo=").Append(combo);
    if(combo!=IntPtr.Zero){
      IntPtr count=Send(combo,0x146,IntPtr.Zero,IntPtr.Zero);
      o.Append(" count=").Append(count);
      if(count.ToInt32()>=1 && count.ToInt32()<=32){
        Send(combo,0x14e,IntPtr.Zero,IntPtr.Zero);
        PostMessageW(found,0x111,new IntPtr((1<<16)|1013),combo);
        IntPtr ok=GetDlgItem(found,1);
        o.Append(" ok=").Append(ok);
        if(ok!=IntPtr.Zero) PostMessageW(ok,0xf5,IntPtr.Zero,IntPtr.Zero);
        o.Append(" clicked");
      }
    }
    return o.ToString();
  }
}
'@
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
Start-Sleep -Seconds 2
$browser = Start-Process -FilePath 'C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe' -WindowStyle Hidden -PassThru
$sw = [Diagnostics.Stopwatch]::StartNew()
$log = Join-Path $lab 'selectdiag.txt'
while ($sw.Elapsed.TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 2000
    $line = ('{0:000.0} {1}' -f $sw.Elapsed.TotalSeconds, [DiagUI]::Attempt())
    Add-Content -LiteralPath $log -Value $line -Encoding utf8
    if ($line -match 'clicked') { break }
}
Get-Process -Id $browser.Id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
taskkill /f /im LockDownBrowser.exe 2>$null | Out-Null
'selectdiag done'
