// Diagnostic candidate: keep original executable code and all allocations.
// Only empty the heap strings used by the version-pinned process-rule table.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace ProcessPolicyRewrite
{
    internal static class PolicyDataExperiment
    {
        const string ExpectedHash = "635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582";
        static readonly int[] MatchFields = { 8, 16, 32, 40 };
        static readonly Dictionary<int,string> Anchors = new Dictionary<int,string> {
            {6,"Messenger"},{9,"DeskPins"},{17,"Synergy"},{22,"Windows Sidebar"}
        };

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
            // Validate every pointer before changing any of the table's strings.
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
        static int Main(string[] arguments)
        {
            Native.ProcessInfo child=new Native.ProcessInfo();
            bool active=false;
            using(TraceLog log=new TraceLog(Options.Parse(arguments).Log))
            try
            {
                Options options=Options.Parse(arguments);
                string target=TargetDiscovery.Resolve(options.Target,"LockDownBrowser.exe",ExpectedHash);
                byte[] source=File.ReadAllBytes(target);
                using(SHA256 sha=SHA256.Create()) PeImage.Require(BitConverter.ToString(sha.ComputeHash(source)).Replace("-","").ToLowerInvariant()==ExpectedHash,"Wrong target");
                PeImage image=new PeImage(source);
                Native.StartupInfo startup=new Native.StartupInfo();startup.cb=Marshal.SizeOf(typeof(Native.StartupInfo));
                StringBuilder command=new StringBuilder(Program.Quote(target));
                foreach(string argument in options.Forward) command.Append(" ").Append(Program.Quote(argument));
                log.Event("preflight",new {sha256=ExpectedHash,patchCount=0,mode="private-heap-policy-data"});
                if(!Native.CreateProcessW(target,command,IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,Path.GetDirectoryName(target),ref startup,out child))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                log.Event("child_created_suspended",new {pid=child.processId});
                Native.BasicInfo basic;uint returned;
                PeImage.Require(Native.NtQueryInformationProcess(child.process,0,out basic,(uint)Marshal.SizeOf(typeof(Native.BasicInfo)),out returned)>=0,"Cannot read PEB");
                long imageBase=Pointer(child.process,basic.peb.ToInt64()+0x10);
                PeImage.Require(Native.ResumeThread(child.thread)==1,"Unexpected suspend count");
                var elapsed=System.Diagnostics.Stopwatch.StartNew();
                bool first=true;
                string previousFailure=null;
                while(Native.WaitForSingleObject(child.process,active?250U:5U)==0x102)
                {
                    try
                    {
                        long state,table;int count;
                        if(Observe(child.process,imageBase,out state,out table,out count))
                        {
                            BrowserReadiness.Suspend(child.process);
                            int cleared;
                            try { cleared=ClearMatches(child.process,imageBase,log); }
                            finally { BrowserReadiness.Resume(child.process); }
                            if(cleared>=0 && first) { first=false;active=true;log.Event("child_resumed",new {pid=child.processId,mode="private-heap-policy-data"}); }
                        }
                    }
                    catch(Win32Exception error) {
                        if(active) throw;
                        if(previousFailure!=error.Message) { previousFailure=error.Message;log.Event("policy_wait",new {message=error.Message}); }
                    }
                    catch(InvalidDataException error) {
                        if(active) throw;
                        if(previousFailure!=error.Message) { previousFailure=error.Message;log.Event("policy_wait",new {message=error.Message}); }
                    }
                    if(!active && elapsed.ElapsedMilliseconds>60000) throw new TimeoutException("Policy table not initialized");
                }
                uint code;PeImage.Require(Native.GetExitCodeProcess(child.process,out code),"Cannot read child exit code");
                log.Event("child_exit",new {pid=child.processId,code=code});
                return unchecked((int)code);
            }
            catch(Exception error)
            {
                log.Event("error",new {message=error.GetType().Name+": "+error.Message,active=active});
                if(child.process!=IntPtr.Zero) { Native.TerminateProcess(child.process,0xE0000001);Native.WaitForSingleObject(child.process,5000); }
                return 1;
            }
            finally
            {
                if(child.thread!=IntPtr.Zero) Native.CloseHandle(child.thread);
                if(child.process!=IntPtr.Zero) Native.CloseHandle(child.process);
            }
        }
    }
}
