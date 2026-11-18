// Lab probe: after clearing the startup rule table, find where a SECOND copy
// of the process-rule strings lives in the child's private heap, and observe
// whether decoys named for the second catalog survive.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace ProcessPolicyRewrite
{
    internal static class TableHunter
    {
        const string ExpectedHash = "635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582";
        static readonly int[] MatchFields = { 8, 16, 32, 40 };
        static readonly Dictionary<int,string> Anchors = new Dictionary<int,string> {
            {6,"Messenger"},{9,"DeskPins"},{17,"Synergy"},{22,"Windows Sidebar"}
        };
        // Distinctive strings present in the second catalog region of the blob,
        // in both byte encodings the runtime could use for comparison.
        static readonly byte[][] Patterns = new byte[][] {
            Encoding.ASCII.GetBytes("ecapn.dll"),
            Encoding.ASCII.GetBytes("iris.exe"),
            Encoding.ASCII.GetBytes("SunloginClient"),
            Encoding.Unicode.GetBytes("ecapn.dll"),
            Encoding.Unicode.GetBytes("iris.exe"),
            Encoding.Unicode.GetBytes("SunloginClient"),
        };


        // ---- dialog automation (server selection / startup notice) ----
        private delegate bool WindowCallback(IntPtr window, IntPtr value);
        [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr value);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int length);
        [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr window, int id);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr window, WindowCallback callback, IntPtr value);
        [DllImport("user32.dll")] private static extern IntPtr SendMessageW(IntPtr window, uint message, IntPtr first, IntPtr second);
        [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr window, uint message, IntPtr first, IntPtr second);

        private static string WindowText(IntPtr window)
        {
            StringBuilder text = new StringBuilder(512);
            GetWindowTextW(window, text, text.Capacity);
            return text.ToString();
        }

        // Click OK on the Choose Server dialog owned by the child; returns true when done.
        private static bool SelectServer(uint childPid)
        {
            bool done = false;
            EnumWindows(delegate(IntPtr window, IntPtr value)
            {
                uint owner; GetWindowThreadProcessId(window, out owner);
                if (owner != childPid || !IsWindowVisible(window) || WindowText(window) != "Choose Server")
                    return true;
                IntPtr combo = GetDlgItem(window, 1013);
                if (combo == IntPtr.Zero) return true;
                SendMessageW(combo, 0x14e, IntPtr.Zero, IntPtr.Zero);           // CB_SETCURSEL 0
                PostMessageW(window, 0x111, new IntPtr((1 << 16) | 1013), combo); // WM_COMMAND
                IntPtr ok = GetDlgItem(window, 1);
                if (ok != IntPtr.Zero) PostMessageW(ok, 0xf5, IntPtr.Zero, IntPtr.Zero); // BM_CLICK
                done = true;
                return false;
            }, IntPtr.Zero);
            return done;
        }

        // Dismiss the Windows Update startup warning if it appears (click OK).
        private static bool AcknowledgeUpdateWarning(uint childPid)
        {
            bool done = false;
            EnumWindows(delegate(IntPtr window, IntPtr value)
            {
                uint owner; GetWindowThreadProcessId(window, out owner);
                if (owner != childPid || !IsWindowVisible(window)) return true;
                StringBuilder combined = new StringBuilder();
                EnumChildWindows(window, delegate(IntPtr child, IntPtr unused)
                {
                    combined.Append(WindowText(child)); combined.Append(" | ");
                    return true;
                }, IntPtr.Zero);
                if (combined.ToString().IndexOf("Windows Update is active") < 0) return true;
                IntPtr ok = GetDlgItem(window, 1);
                if (ok != IntPtr.Zero) PostMessageW(ok, 0xf5, IntPtr.Zero, IntPtr.Zero);
                done = true;
                return false;
            }, IntPtr.Zero);
            return done;
        }


        // Read the periodic-scan gate slots in the state object.
        static Dictionary<string,object> GateSnapshot(IntPtr process, long state)
        {
            Dictionary<string,object> result=new Dictionary<string,object>();
            if(state<0x10000) return result;
            try
            {
                int f388=BitConverter.ToInt32(Program.Read(process,state+0xf388,4),0);
                int f390=BitConverter.ToInt32(Program.Read(process,state+0xf390,4),0);
                result["f388"]=f388; result["f390"]=f390;
            }
            catch(Win32Exception) { result["f388"]="read-failed"; result["f390"]="read-failed"; }
            return result;
        }

        static long Pointer(IntPtr process, long address) { return BitConverter.ToInt64(Program.Read(process,address,8),0); }
        static string CString(IntPtr process,long pointer)
        {
            byte[] text = Program.Read(process,pointer,128);
            int end = Array.IndexOf(text,(byte)0);
            if(end<0) throw new InvalidDataException("Missing string terminator in policy anchor");
            return Encoding.ASCII.GetString(text,0,end);
        }
        static void RequireWritableHeap(IntPtr process,long address,int count)
        {
            Native.MemoryBasicInformation info;
            if(Native.VirtualQueryEx(process,new IntPtr(address),out info,(UIntPtr)Marshal.SizeOf(typeof(Native.MemoryBasicInformation)))==IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint protection=info.Protect&0xff;
            PeImage.Require(info.State==0x1000 && info.Type==0x20000 &&
                (info.Protect&0x100)==0 && (protection==4 || protection==8) &&
                address>=info.BaseAddress.ToInt64() &&
                address+count<=info.BaseAddress.ToInt64()+info.RegionSize.ToInt64(),
                "Policy data is not in a writable private heap region");
        }
        static bool Observe(IntPtr process,long imageBase,out long state,out long table,out int count)
        {
            state=Pointer(process,imageBase+0xcff1e8);table=0;count=0;
            if(state<0x10000) return false;
            table=Pointer(process,state+0x23408);
            count=BitConverter.ToInt32(Program.Read(process,state+0x23410,4),0);
            if(count!=1166 || table<0x10000) return false;
            RequireWritableHeap(process,table,count*64);
            foreach(KeyValuePair<int,string> anchor in Anchors)
                if(CString(process,Pointer(process,table+anchor.Key*64))!=anchor.Value) return false;
            return true;
        }
        static int ClearMatches(IntPtr process,long imageBase,TraceLog log)
        {
            long state,table;int count;
            if(!Observe(process,imageBase,out state,out table,out count)) return -1;
            List<long> addresses=new List<long>();
            HashSet<long> unique=new HashSet<long>();
            byte[] records=Program.Read(process,table,count*64);
            for(int i=0;i<count;i++) foreach(int field in MatchFields)
            {
                long pointer=BitConverter.ToInt64(records,i*64+field);
                PeImage.Require(pointer>=0x10000,"Policy table has an uninitialized match string");
                RequireWritableHeap(process,pointer,1);
                if(Program.Read(process,pointer,1)[0]!=0 && unique.Add(pointer)) addresses.Add(pointer);
            }
            foreach(long address in addresses)
            {
                UIntPtr written;
                if(!Native.WriteProcessMemory(process,new IntPtr(address),new byte[]{0},new UIntPtr(1),out written) ||
                   written.ToUInt64()!=1 || Program.Read(process,address,1)[0]!=0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot clear policy match string");
            }
            if(addresses.Count>0) log.Event("policy_data_verified",new {rules=count,strings=addresses.Count,
                state="0x"+state.ToString("x"),table="0x"+table.ToString("x"),executableMemoryChanged=false});
            return addresses.Count;
        }

        static void FindAll(byte[] haystack, byte[] needle, long baseAddress, List<long> hits)
        {
            int index=0;
            while((index=Array.IndexOf(haystack,needle,index))>=0)
            {
                hits.Add(baseAddress+index);
                ++index;
            }
        }

        // Scan committed private RW regions for the catalog patterns; returns the
        // distinct region bases that produced hits.
        static List<long> ScanHeap(IntPtr process, TraceLog log)
        {
            List<object> findings=new List<object>();
            HashSet<long> hitRegions=new HashSet<long>();
            long address=0x10000;
            while(address<0x7FFFFFFFFFFF)
            {
                Native.MemoryBasicInformation info;
                if(Native.VirtualQueryEx(process,new IntPtr(address),out info,(UIntPtr)Marshal.SizeOf(typeof(Native.MemoryBasicInformation)))==IntPtr.Zero) break;
                long size=info.RegionSize.ToInt64();
                uint protection=info.Protect&0xff;
                if(info.State==0x1000 && info.Type==0x20000 && (info.Protect&0x100)==0 &&
                   (protection==4 || protection==8) && size<=256*1024*1024)
                {
                    try
                    {
                        byte[] region=new byte[size];
                        UIntPtr read;
                        if(Native.ReadProcessMemory(process,info.BaseAddress,region,new UIntPtr((uint)size),out read) &&
                           read.ToUInt64()==(ulong)size)
                        {
                            foreach(byte[] pattern in Patterns)
                            {
                                List<long> hits=new List<long>();
                                FindAll(region,pattern,info.BaseAddress.ToInt64(),hits);
                                foreach(long hit in hits)
                                {
                                    int offset=(int)(hit-info.BaseAddress.ToInt64());
                                    int from=Math.Max(0,offset-160), to=Math.Min(region.Length,offset+160);
                                    findings.Add(new {
                                        pattern=Encoding.ASCII.GetString(pattern),
                                        address="0x"+hit.ToString("x"),
                                        region="0x"+info.BaseAddress.ToInt64().ToString("x"),
                                        regionSize=size,
                                        context=Convert.ToBase64String(region,from,to-from)
                                    });
                                    hitRegions.Add(info.BaseAddress.ToInt64());
                                }
                            }
                        }
                    }
                    catch(Win32Exception) { }
                }
                checked { try { address=info.BaseAddress.ToInt64()+size; } catch(OverflowException) { break; } }
            }
            log.Event("heap_scan",new {findings=findings.Count,items=findings});
            return new List<long>(hitRegions);
        }

        // Look inside the state object window for pointer slots targeting the hit regions.
        static void ScanStatePointers(IntPtr process,long state,TraceLog log,List<long> hitRegions)
        {
            List<object> slots=new List<object>();
            byte[] window=new byte[0x30000];
            UIntPtr read;
            if(!Native.ReadProcessMemory(process,new IntPtr(state),window,new UIntPtr((uint)window.Length),out read))
            {
                log.Event("state_scan_failed",new {error=Marshal.GetLastWin32Error()});
                return;
            }
            int have=(int)read.ToUInt64();
            for(int i=0;i+8<=have;i+=4)
            {
                long value=BitConverter.ToInt64(window,i);
                foreach(long region in hitRegions)
                {
                    if(value>=region && value<region+0x2000000)
                    {
                        slots.Add(new {slotOffset="0x"+i.ToString("x"),value="0x"+value.ToString("x"),
                                        region="0x"+region.ToString("x")});
                        break;
                    }
                }
            }
            log.Event("state_pointer_slots",new {state="0x"+state.ToString("x"),slots=slots});
        }

        static int Main(string[] arguments)
        {
            Native.ProcessInfo child=new Native.ProcessInfo();
            List<Native.ProcessInfo> triggers=new List<Native.ProcessInfo>();
            List<string> triggerNames=new List<string>{"IrisPortable.exe","sunloginclient.exe","deskpins.exe"};
            bool active=false;
            using(TraceLog log=new TraceLog(Options.Parse(arguments).Log))
            try
            {
                Options options=Options.Parse(arguments);
                string target=TargetDiscovery.Resolve(options.Target,"LockDownBrowser.exe",ExpectedHash);
                byte[] source=File.ReadAllBytes(target);
                using(SHA256 sha=SHA256.Create()) PeImage.Require(BitConverter.ToString(sha.ComputeHash(source)).Replace("-","").ToLowerInvariant()==ExpectedHash,"Wrong target");
                // Spawn the decoy processes first (renamed copies of cmd.exe).
                foreach(string name in triggerNames)
                {
                    string decoy=Path.Combine("C:\\NpgLab",name);
                    File.Copy(Environment.SystemDirectory+"\\cmd.exe",decoy,true);
                    Native.ProcessInfo trigger=new Native.ProcessInfo();
                    Native.StartupInfo startup=new Native.StartupInfo();startup.cb=Marshal.SizeOf(typeof(Native.StartupInfo));
                    StringBuilder command=new StringBuilder(Program.Quote(decoy)+" /k title TableHunter decoy");
                    if(!Native.CreateProcessW(decoy,command,IntPtr.Zero,IntPtr.Zero,false,0x20,IntPtr.Zero,"C:\\NpgLab",ref startup,out trigger))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    triggers.Add(trigger);
                }
                log.Event("decoys_created",new {names=triggerNames,
                    pids=triggers.ConvertAll(delegate(Native.ProcessInfo t){return (object)t.processId;})});
                Native.StartupInfo childStartup=new Native.StartupInfo();childStartup.cb=Marshal.SizeOf(typeof(Native.StartupInfo));
                StringBuilder childCommand=new StringBuilder(Program.Quote(target));
                foreach(string argument in options.Forward) childCommand.Append(" ").Append(Program.Quote(argument));
                log.Event("preflight",new {sha256=ExpectedHash,mode="table-hunter"});
                if(!Native.CreateProcessW(target,childCommand,IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,Path.GetDirectoryName(target),ref childStartup,out child))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                log.Event("child_created_suspended",new {pid=child.processId});
                Native.BasicInfo basic;uint returned;
                PeImage.Require(Native.NtQueryInformationProcess(child.process,0,out basic,(uint)Marshal.SizeOf(typeof(Native.BasicInfo)),out returned)>=0,"Cannot read PEB");
                long imageBase=Pointer(child.process,basic.peb.ToInt64()+0x10);
                PeImage.Require(Native.ResumeThread(child.thread)==1,"Unexpected suspend count");
                var elapsed=System.Diagnostics.Stopwatch.StartNew();
                string previousFailure=null;
                long state=0;long table=0;int count=0;
                bool cleared=false, selected=false, deathLogged=false;
                int rearmCount=0;
                long nextScan=0;
                List<object> samples=new List<object>();
                while(Native.WaitForSingleObject(child.process,250U)==0x102)
                {
                    if(!cleared)
                    {
                        try
                        {
                            if(Observe(child.process,imageBase,out state,out table,out count))
                            {
                                BrowserReadiness.Suspend(child.process);
                                int strings;
                                try { strings=ClearMatches(child.process,imageBase,log); }
                                finally { BrowserReadiness.Resume(child.process); }
                                if(strings>=0)
                                {
                                    cleared=true;active=true;
                                    log.Event("table1_cleared",new {pid=child.processId,rules=count});
                                }
                            }
                        }
                        catch(Win32Exception error) { if(previousFailure!=error.Message){previousFailure=error.Message;log.Event("policy_wait",new {message=error.Message});} }
                        catch(InvalidDataException error) { if(previousFailure!=error.Message){previousFailure=error.Message;log.Event("policy_wait",new {message=error.Message});} }
                        if(!cleared && elapsed.ElapsedMilliseconds>60000) throw new TimeoutException("Policy table not initialized");
                    }
                    else
                    {
                        // After the first table is cleared, drive the startup dialogs so the
                        // browser crosses the server-selection threshold; the suspected second
                        // kill path may only engage once the session environment is active.
                        if(!selected)
                        {
                            AcknowledgeUpdateWarning(child.processId);
                            if(SelectServer(child.processId))
                            {
                                selected=true;
                                nextScan=elapsed.ElapsedMilliseconds+8000;
                                // Kill the periodic-scan gate right after the session engages.
                                BrowserReadiness.Suspend(child.process);
                                try
                                {
                                    Dictionary<string,object> before=GateSnapshot(child.process,state);
                                    UIntPtr written;
                                    Native.WriteProcessMemory(child.process,new IntPtr(state+0xf388),new byte[]{0,0,0,0},new UIntPtr(4),out written);
                                    Native.WriteProcessMemory(child.process,new IntPtr(state+0xf390),new byte[]{0,0,0,0},new UIntPtr(4),out written);
                                    Dictionary<string,object> after=GateSnapshot(child.process,state);
                                    log.Event("server_selected",new {pid=child.processId,
                                        seconds=Math.Round(elapsed.Elapsed.TotalSeconds,2),
                                        gateBefore=before,gateAfter=after});
                                }
                                finally { BrowserReadiness.Resume(child.process); }
                            }
                        }
                        else
                        {
                            // Continuous gate-keeper: zero the periodic-scan arming flag
                            // whenever the session re-arms it (observed: it flips 0->1 about
                            // 2.3s after server selection; the kill follows ~2.3s later).
                            if(state>=0x10000)
                            {
                                try
                                {
                                    int f388=BitConverter.ToInt32(Program.Read(child.process,state+0xf388,4),0);
                                    if(f388!=0)
                                    {
                                        BrowserReadiness.Suspend(child.process);
                                        try
                                        {
                                            UIntPtr written;
                                            Native.WriteProcessMemory(child.process,new IntPtr(state+0xf388),
                                                new byte[]{0,0,0,0},new UIntPtr(4),out written);
                                            Native.WriteProcessMemory(child.process,new IntPtr(state+0xf390),
                                                new byte[]{0,0,0,0},new UIntPtr(4),out written);
                                        }
                                        finally { BrowserReadiness.Resume(child.process); }
                                        rearmCount++;
                                        log.Event("gate_rearmed_and_cleared",new {
                                            seconds=Math.Round(elapsed.Elapsed.TotalSeconds,2),
                                            f388=f388, rearm=rearmCount});
                                    }
                                }
                                catch(Win32Exception) { }
                            }
                        }
                        List<object> alive=triggers.ConvertAll(delegate(Native.ProcessInfo t){return (object)(Native.WaitForSingleObject(t.process,0)==0x102);});
                        samples.Add(new {
                            seconds=Math.Round(elapsed.Elapsed.TotalSeconds,2),
                            selected=selected,
                            gate=GateSnapshot(child.process,state),
                            alive=alive
                        });
                        bool anyDead=false;
                        foreach(object a in alive) if(!(bool)a) anyDead=true;
                        if(anyDead && !deathLogged)
                        {
                            deathLogged=true;
                            // A decoy just died: capture memory immediately.
                            List<long> hitRegions=ScanHeap(child.process,log);
                            if(hitRegions.Count>0 && state>=0x10000)
                                ScanStatePointers(child.process,state,log,hitRegions);
                            log.Event("decoy_death",new {
                                seconds=Math.Round(elapsed.Elapsed.TotalSeconds,2), alive=alive});
                        }
                        System.Threading.Thread.Sleep(500);
                    }
                    if(elapsed.ElapsedMilliseconds>240000)
                    {
                        log.Event("probe_timeout",new {pid=child.processId});
                        Native.TerminateProcess(child.process,0xE0000002);
                        Native.WaitForSingleObject(child.process,5000);
                        break;
                    }
                }
                uint code;
                if(Native.GetExitCodeProcess(child.process,out code)) log.Event("child_exit",new {pid=child.processId,code=code});
                log.Event("final_samples",new {samples=samples});
                return 0;
            }
            catch(Exception error)
            {
                log.Event("error",new {message=error.GetType().Name+": "+error.Message,active=active});
                if(child.process!=IntPtr.Zero){Native.TerminateProcess(child.process,0xE0000001);Native.WaitForSingleObject(child.process,5000);}
                return 1;
            }
            finally
            {
                foreach(Native.ProcessInfo trigger in triggers)
                {
                    if(trigger.process!=IntPtr.Zero){Native.TerminateProcess(trigger.process,0);Native.CloseHandle(trigger.process);}
                }
                if(child.thread!=IntPtr.Zero) Native.CloseHandle(child.thread);
                if(child.process!=IntPtr.Zero) Native.CloseHandle(child.process);
            }
        }
    }
}
