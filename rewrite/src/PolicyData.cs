using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ProcessPolicyRewrite
{
    // Process-rule activation by emptying the match strings of the rule table
    // in the new browser's private heap. The launcher never modifies an
    // executable page, so the original's code-integrity checks observe an
    // untouched image, and the process scan finds nothing to complain about.
    //
    // The layout constants are pinned to the exact supported build, the same
    // way the code-patch plan is: the state pointer at 0xcff1e8 leads to the
    // decrypted table (count 1166, 64 bytes per rule) and four known display
    // names anchor the record indices before anything is changed.
    internal static class PolicyData
    {
        const long StatePointerRva = 0xcff1e8;
        const long TableOffset = 0x23408;
        const long CountOffset = 0x23410;
        const int ExpectedRules = 1166;
        const int InitialTimeoutMilliseconds = 90000;
        static readonly int[] MatchFields = { 8, 16, 32, 40 };
        static readonly Dictionary<int, string> Anchors = new Dictionary<int, string> {
            { 6, "Messenger" }, { 9, "DeskPins" }, { 17, "Synergy" }, { 22, "Windows Sidebar" }
        };

        static long Pointer(IntPtr process, long address)
        {
            return BitConverter.ToInt64(Program.Read(process, address, 8), 0);
        }

        static string CString(IntPtr process, long pointer)
        {
            byte[] text = Program.Read(process, pointer, 128);
            int end = Array.IndexOf(text, (byte)0);
            if (end < 0) throw new InvalidDataException("Missing string terminator in policy anchor");
            return Encoding.ASCII.GetString(text, 0, end);
        }

        static void RequireWritableHeap(IntPtr process, long address, int count)
        {
            Native.MemoryBasicInformation info;
            if (Native.VirtualQueryEx(process, new IntPtr(address), out info,
                    (UIntPtr)Marshal.SizeOf(typeof(Native.MemoryBasicInformation))) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint protection = info.Protect & 0xff;
            PeImage.Require(info.State == 0x1000 && info.Type == 0x20000 &&
                (info.Protect & 0x100) == 0 && (protection == 4 || protection == 8) &&
                address >= info.BaseAddress.ToInt64() &&
                address + count <= info.BaseAddress.ToInt64() + info.RegionSize.ToInt64(),
                "Policy data is not in a writable private heap region");
        }

        static bool Observe(IntPtr process, long imageBase, out long state, out long table, out int count)
        {
            state = Pointer(process, imageBase + StatePointerRva);
            table = 0;
            count = 0;
            if (state < 0x10000) return false;
            table = Pointer(process, state + TableOffset);
            count = BitConverter.ToInt32(Program.Read(process, state + CountOffset, 4), 0);
            if (count != ExpectedRules || table < 0x10000) return false;
            RequireWritableHeap(process, table, count * 64);
            foreach (KeyValuePair<int, string> anchor in Anchors)
                if (CString(process, Pointer(process, table + anchor.Key * 64)) != anchor.Value) return false;
            return true;
        }

        static int ClearMatches(IntPtr process, long imageBase, TraceLog log)
        {
            long state, table;
            int count;
            if (!Observe(process, imageBase, out state, out table, out count)) return -1;
            List<long> addresses = new List<long>();
            HashSet<long> unique = new HashSet<long>();
            // Validate every pointer before changing any of the table's strings.
            byte[] records = Program.Read(process, table, count * 64);
            for (int i = 0; i < count; ++i)
                foreach (int field in MatchFields)
                {
                    long pointer = BitConverter.ToInt64(records, i * 64 + field);
                    PeImage.Require(pointer >= 0x10000, "Policy table has an uninitialized match string");
                    RequireWritableHeap(process, pointer, 1);
                    if (Program.Read(process, pointer, 1)[0] != 0 && unique.Add(pointer)) addresses.Add(pointer);
                }
            foreach (long address in addresses)
            {
                UIntPtr written;
                if (!Native.WriteProcessMemory(process, new IntPtr(address), new byte[] { 0 },
                        new UIntPtr(1), out written) || written.ToUInt64() != 1 ||
                    Program.Read(process, address, 1)[0] != 0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot clear policy match string");
            }
            if (addresses.Count > 0)
                log.Event("policy_data_verified", new {
                    rules = count, strings = addresses.Count,
                    state = "0x" + state.ToString("x"), table = "0x" + table.ToString("x"),
                    executableMemoryChanged = false
                });
            return addresses.Count;
        }

        // Blocks until the browser has decrypted its rule table and the match
        // strings are emptied, then keeps watching for table re-initialization
        // and for the periodic-scan arming flag until the browser exits. The
        // session arms state+0xf388 once (observed ~2.3s after the server
        // selection, kill ~2.3s later); zeroing the armed flag prevents the
        // periodic process sweep with no other observed effect. Failures before
        // activation are fatal; after activation they are logged and tolerated.
        internal static void Activate(IntPtr process, long imageBase, TraceLog log)
        {
            Stopwatch elapsed = Stopwatch.StartNew();
            bool active = false;
            string previousFailure = null;
            long knownState = 0;
            while (Native.WaitForSingleObject(process, active ? 250U : 5U) == 0x102)
            {
                try
                {
                    long state, table;
                    int count;
                    if (Observe(process, imageBase, out state, out table, out count))
                    {
                        knownState = state;
                        BrowserReadiness.Suspend(process);
                        int cleared;
                        try { cleared = ClearMatches(process, imageBase, log); }
                        finally { BrowserReadiness.Resume(process); }
                        if (cleared >= 0 && !active)
                        {
                            active = true;
                            log.Event("policy_activated", new { pid = 0, rules = count });
                        }
                    }
                    if (active && knownState >= 0x10000)
                    {
                        // Gate-keeper: the session arms the periodic process
                        // sweep exactly once; clear it the moment it appears.
                        int armed = BitConverter.ToInt32(Program.Read(process, knownState + 0xf388, 4), 0);
                        if (armed != 0)
                        {
                            BrowserReadiness.Suspend(process);
                            try
                            {
                                UIntPtr written;
                                if (!Native.WriteProcessMemory(process, new IntPtr(knownState + 0xf388),
                                        new byte[] { 0, 0, 0, 0 }, new UIntPtr(4), out written))
                                    throw new Win32Exception(Marshal.GetLastWin32Error());
                                Native.WriteProcessMemory(process, new IntPtr(knownState + 0xf390),
                                    new byte[] { 0, 0, 0, 0 }, new UIntPtr(4), out written);
                            }
                            finally { BrowserReadiness.Resume(process); }
                            log.Event("periodic_scan_gate_cleared", new {
                                armed = armed,
                                state = "0x" + knownState.ToString("x") });
                        }
                    }
                }
                catch (Win32Exception error)
                {
                    if (active)
                    {
                        if (previousFailure != error.Message)
                        {
                            previousFailure = error.Message;
                            log.Event("policy_data_watch", new { message = error.Message });
                        }
                    }
                    else if (previousFailure != error.Message)
                    {
                        previousFailure = error.Message;
                        log.Event("policy_wait", new { message = error.Message });
                    }
                }
                catch (InvalidDataException error)
                {
                    if (active)
                    {
                        if (previousFailure != error.Message)
                        {
                            previousFailure = error.Message;
                            log.Event("policy_data_watch", new { message = error.Message });
                        }
                    }
                    else if (previousFailure != error.Message)
                    {
                        previousFailure = error.Message;
                        log.Event("policy_wait", new { message = error.Message });
                    }
                }
                if (!active && elapsed.ElapsedMilliseconds > InitialTimeoutMilliseconds)
                    throw new TimeoutException("The original browser did not initialize its process rule table within " +
                        InitialTimeoutMilliseconds + " milliseconds");
            }
        }
    }
}
