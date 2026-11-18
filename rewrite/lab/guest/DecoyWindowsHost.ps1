# Third-path window decoy host (run detached).
# Owns the windows the timer kill (0x140245530) classifies so the sampler
# process itself is never the victim: XLMAIN/OpusApp-class Excel/Word windows,
# AutoHotkeyGUI, and the caption-matched Sticky Keys / Save a / Print /
# Power Options / Wireless display toolbar decoys.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Continue'
$dir = 'C:\NpgLab\3rd'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DecoyWin {
  public delegate IntPtr Proc(IntPtr window, uint message, IntPtr first, IntPtr second);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct WNDCLASSEX { public uint size, style; public Proc procedure; public int classBytes, windowBytes;
    public IntPtr instance, icon, cursor, background; public string menu, name; public IntPtr smallIcon; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
  static extern ushort RegisterClassExW(ref WNDCLASSEX value);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
  static extern IntPtr CreateWindowExW(uint extra, string className, string title, uint style,
      int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
  [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr window, uint message, IntPtr first, IntPtr second);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
  static readonly Proc Procedure = DefWindowProcW;
  public static void Create(string className, string title, int x) {
    var value = new WNDCLASSEX();
    value.size = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
    value.procedure = Procedure;
    value.instance = Marshal.GetHINSTANCE(typeof(DecoyWin).Module);
    value.name = className;
    RegisterClassExW(ref value);
    IntPtr window = CreateWindowExW(0, className, title, 0x00CF0000, x, 30, 240, 60,
        IntPtr.Zero, IntPtr.Zero, value.instance, IntPtr.Zero);
    if (window == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    ShowWindow(window, 5);
    ShowWindow(window, 5); // first call of a hidden-started process applies STARTUPINFO's SW_HIDE instead
  }
}
'@
[DecoyWin]::Create('XLMAIN', 'Microsoft Excel - decoy', 30)
[DecoyWin]::Create('AutoHotkeyGUI', 'AutoHotkey decoy', 300)
[DecoyWin]::Create('NpgDecoyWnd', 'Sticky Keys', 570)
[DecoyWin]::Create('NpgDecoyWnd', 'Save as decoy', 30)
[DecoyWin]::Create('NpgDecoyWnd', 'Print', 300)
[DecoyWin]::Create('NpgDecoyWnd', 'Power Options', 570)
[DecoyWin]::Create('NpgDecoyWnd', 'Wireless display toolbar', 30)
[IO.File]::WriteAllText((Join-Path $dir 'windowhost.pid'), "$PID", [Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 700
