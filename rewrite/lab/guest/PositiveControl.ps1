[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
$lab='C:\NpgLab'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class GateUI {
 public delegate bool CB(IntPtr w,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(CB cb,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w,CB cb,IntPtr p);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr w,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr w,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr w);
 [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr w,int id);
 [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr w,uint msg,IntPtr a,IntPtr b);
 [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr w,uint msg,IntPtr a,IntPtr b);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr w,uint msg,IntPtr a,StringBuilder b);
 static string Text(IntPtr w) {var s=new StringBuilder(2048);GetWindowTextW(w,s,s.Capacity);return s.ToString();}
 static string Class(IntPtr w) {var s=new StringBuilder(256);GetClassNameW(w,s,s.Capacity);return s.ToString();}
 public static object[] Snapshot() {
  var r=new List<object>();EnumWindows((w,p)=>{
   if(!IsWindowVisible(w)) return true;string title=Text(w),cls=Class(w);uint pid;GetWindowThreadProcessId(w,out pid);
   if(cls=="#32770"||title.Contains("LockDown")||title.Contains("Authorization")) {
    var children=new List<object>();EnumChildWindows(w,(c,v)=>{string t=Text(c);if(t.Length>0||Class(c)=="Button")children.Add(new{handle=c.ToInt64(),id=GetDlgCtrlID(c),cls=Class(c),text=t});return true;},IntPtr.Zero);
    r.Add(new{handle=w.ToInt64(),pid=pid,title=title,cls=cls,children=children.ToArray()});
   } return true;
  },IntPtr.Zero);return r.ToArray();
 }
 public static object SelectServer() {
  object result=null;EnumWindows((w,p)=>{
   if(!IsWindowVisible(w)||Text(w)!="Choose Server")return true;
   IntPtr combo=GetDlgItem(w,1013);int count=SendMessageW(combo,0x146,IntPtr.Zero,IntPtr.Zero).ToInt32();var entries=new List<string>();
   for(int i=0;i<count;i++){var s=new StringBuilder(2048);SendMessageW(combo,0x148,new IntPtr(i),s);entries.Add(s.ToString());}
   if(count>0){SendMessageW(combo,0x14e,IntPtr.Zero,IntPtr.Zero);PostMessageW(w,0x111,new IntPtr((1<<16)|1013),combo);PostMessageW(GetDlgItem(w,1),0xf5,IntPtr.Zero,IntPtr.Zero);}
   result=new{entries=entries.ToArray(),selected=count>0?0:-1};return false;
  },IntPtr.Zero);return result;
 }
}
'@
Get-Process -Name LockDownBrowser,ExperimentLauncher -ErrorAction SilentlyContinue | Stop-Process -Force
$triggerNames=@('deskpins.exe','sidebar.exe','msmsgs.exe','synergy.exe')
$dir=Join-Path $lab 'positive-triggers';New-Item -ItemType Directory -Force -Path $dir|Out-Null
$triggers=@()
foreach($name in $triggerNames){Copy-Item -LiteralPath "$env:WINDIR\System32\cmd.exe" -Destination (Join-Path $dir $name) -Force;$p=Start-Process -FilePath (Join-Path $dir $name) -ArgumentList '/k title ProcessClose fixture' -WindowStyle Minimized -PassThru;$triggers+=@{name=$name;pid=$p.Id}}
Start-Sleep -Seconds 2
$target='C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe'
$p=Start-Process -FilePath $target -WindowStyle Hidden -PassThru
$samples=@();$selected=$null;$changed=@();$last=''
for($i=0;$i -lt 80;$i++){
 Start-Sleep -Milliseconds 500
 if(-not $selected){$selected=[GateUI]::SelectServer()}
 $windows=[GateUI]::Snapshot();$key=$windows|ConvertTo-Json -Depth 8 -Compress
 if($key -ne $last){$changed+=@{t=($i+1)*0.5;windows=$windows};$last=$key}
 $samples+=@{t=($i+1)*0.5;ldb=@(Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue).Count;alive=@($triggers|ForEach-Object{[bool](Get-Process -Id $_.pid -ErrorAction SilentlyContinue)})}
}
$result=@{targetHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash;startedPid=$p.Id;selectedServer=$selected;triggers=$triggers;windowChanges=$changed;samples=$samples}
Get-Process -Name LockDownBrowser -ErrorAction SilentlyContinue|Stop-Process -Force
foreach($trigger in $triggers){Stop-Process -Id $trigger.pid -Force -ErrorAction SilentlyContinue}
$result|ConvertTo-Json -Depth 12 -Compress
