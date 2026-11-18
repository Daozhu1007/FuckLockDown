"""Enqueue agent-side UI step commands on a cadence.

The detached experiment scripts cannot reliably drive the browser UI
(observed 2026-11-18: their EnumWindows never sees the Choose Server dialog
while decoys are present, while agent-run commands see and click it fine).
Each enqueued command performs one UI step in the agent session: dismiss the
update warning, select the first server, dismiss any close-app prompt, and
probe the XLMAIN decoy window's visibility (the beta timer-kill signal).
Every step appends one line to C:\\NpgLab\\3rd\\ui-events.log, which the
experiment script embeds in its final report.
"""

import sys

sys.path.insert(0, "lab")
from enqueue_cmd import enqueue_text

STEP = r"""Add-Type @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class AgentUI {
  public delegate bool CB(IntPtr w, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(CB cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w, CB cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr w, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr w, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr w, uint m, IntPtr a, IntPtr b);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr w, uint m, IntPtr a, IntPtr b);
  static string T(IntPtr w){var s=new StringBuilder(2048);GetWindowTextW(w,s,s.Capacity);return s.ToString();}
  static string C(IntPtr w){var s=new StringBuilder(256);GetClassNameW(w,s,s.Capacity);return s.ToString();}
  public static string Step() {
    bool update=false, close=false, selected=false, xlmainFound=false, xlmainVisible=false;
    string closeText="";
    IntPtr choose=IntPtr.Zero;
    EnumWindows((w,p)=>{
      string c=C(w);
      if(c=="XLMAIN"){ xlmainFound=true; if(IsWindowVisible(w)) xlmainVisible=true; }
      if(!IsWindowVisible(w)) return true;
      string t=T(w);
      if(t=="Choose Server") choose=w;
      if(c=="#32770"){
        var b=new StringBuilder();
        EnumChildWindows(w,(ch,v)=>{b.Append(T(ch));b.Append('|');return true;},IntPtr.Zero);
        string all=b.ToString();
        if(all.IndexOf("Windows Update is active",StringComparison.OrdinalIgnoreCase)>=0){
          IntPtr ok=GetDlgItem(w,1); if(ok!=IntPtr.Zero) PostMessageW(ok,0xf5,IntPtr.Zero,IntPtr.Zero); update=true;
        }
        if(all.IndexOf("Close Application and Continue")>=0){
          // Observation mode: capture what the dialog names (the matched
          // processes) but never click Continue - the original's follow-up
          // action wedged the whole guest session on 2026-11-18.
          close=true;
          closeText=all.Length>500?all.Substring(0,500):all;
        }
      }
      return true;
    },IntPtr.Zero);
    string comboInfo="none";
    if(choose!=IntPtr.Zero){
      IntPtr combo=GetDlgItem(choose,1013);
      IntPtr count=SendMessageW(combo,0x146,IntPtr.Zero,IntPtr.Zero);
      int n=count.ToInt32();
      comboInfo="count="+n;
      if(n>=1 && n<=32){
        SendMessageW(combo,0x14e,IntPtr.Zero,IntPtr.Zero);
        PostMessageW(choose,0x111,new IntPtr((1<<16)|1013),combo);
        IntPtr ok=GetDlgItem(choose,1); if(ok!=IntPtr.Zero) PostMessageW(ok,0xf5,IntPtr.Zero,IntPtr.Zero);
        selected=true;
      }
    }
    return "update=" + update + " close=" + close + " selected=" + selected + " choose=" + comboInfo +
           " xlmain=" + (xlmainFound ? (xlmainVisible?"visible":"hidden") : "gone") +
           (close ? " closeText=" + closeText : "");
  }
}
'@
$r = [AgentUI]::Step()
$line = ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $r)
Add-Content -LiteralPath 'C:\NpgLab\3rd\ui-events.log' -Value $line -Encoding utf8
$line"""


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    for index in range(count):
        enqueue_text(STEP, 30)
        print("ui-step", index, "enqueued")


if __name__ == "__main__":
    main()
