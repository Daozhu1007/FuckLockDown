// Debug-loop tracer: breakpoint-dialog caller identification for the lab.
// Appended to ProcessPolicyLauncher.cs source by build (test-hooks build only).
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ProcessPolicyRewrite
{
    /// <summary>
    /// Experiment-only diagnostic. Attaches as the child's debugger, clears the classic
    /// PEB debug flags, and sets INT3 breakpoints on the dialog/exit APIs. Every hit logs
    /// the caller's return address and a stack window so the checking code can be located
    /// statically afterwards. TerminateProcess and NtTerminateProcess hits have their
    /// process-handle argument replaced with an invalid value so the trace survives.
    /// </summary>
    internal static class Tracer
    {
        private const int EXCEPTION_DEBUG_EVENT = 1;
        private const int CREATE_THREAD_DEBUG_EVENT = 2;
        private const int CREATE_PROCESS_DEBUG_EVENT = 3;
        private const int EXIT_PROCESS_DEBUG_EVENT = 5;
        private const int LOAD_DLL_DEBUG_EVENT = 6;
        private const int EXCEPTION_BREAKPOINT = unchecked((int)0x80000003);
        private const int EXCEPTION_SINGLE_STEP = unchecked((int)0x80000004);
        private const int WatchMilliseconds = 100000;
        private const int PollMilliseconds = 1000;
        private const uint ContinueStatus = 0x00010002u;

        private sealed class Watch
        {
            internal IntPtr Process;
            internal int ProcessId;
            internal TraceLog Log;
            internal Dictionary<int, IntPtr> Threads = new Dictionary<int, IntPtr>();
            internal Dictionary<ulong, byte> Breakpoints = new Dictionary<ulong, byte>();
            internal Dictionary<ulong, string> Names = new Dictionary<ulong, string>();
            internal Dictionary<ulong, string> Modules = new Dictionary<ulong, string>();
            internal HashSet<ulong> Armed = new HashSet<ulong>();
            internal ulong ImageBase;
        }

        [StructLayout(LayoutKind.Explicit, Size = 176)]
        private struct DebugEvent
        {
            [FieldOffset(0)] public int Code;
            [FieldOffset(4)] public int ProcessId;
            [FieldOffset(8)] public int ThreadId;
            // CREATE_PROCESS_DEBUG_INFO
            [FieldOffset(16)] public IntPtr CP_hFile;
            [FieldOffset(24)] public IntPtr CP_hProcess;
            [FieldOffset(32)] public IntPtr CP_hThread;
            [FieldOffset(40)] public IntPtr CP_BaseOfImage;
            [FieldOffset(48)] public IntPtr CP_BaseOfDll;
            [FieldOffset(64)] public IntPtr CP_ThreadLocalBase;
            [FieldOffset(72)] public IntPtr CP_ImageName;
            [FieldOffset(80)] public ushort CP_Unicode;
            // EXCEPTION_DEBUG_INFO
            [FieldOffset(16)] public int Ex_Code;
            [FieldOffset(20)] public int Ex_Flags;
            [FieldOffset(24)] public IntPtr Ex_Address;
            [FieldOffset(32)] public uint Ex_NumberParameters;
            [FieldOffset(40)] public ulong Ex_Parameter0;
            // CREATE_THREAD / LOAD_DLL
            [FieldOffset(16)] public IntPtr Ld_BaseOfDll;
            [FieldOffset(24)] public IntPtr Ld_hFile;
            [FieldOffset(40)] public IntPtr Ld_ImageName;
            [FieldOffset(48)] public ushort Ld_Unicode;
            [FieldOffset(32)] public IntPtr Ct_hThread;
        }

        [StructLayout(LayoutKind.Explicit, Size = 1232)]
        private struct Context
        {
            [FieldOffset(0x30)] public uint ContextFlags;
            [FieldOffset(0x44)] public uint EFlags;
            [FieldOffset(0x78)] public ulong Rax;
            [FieldOffset(0x80)] public ulong Rcx;
            [FieldOffset(0x88)] public ulong Rdx;
            [FieldOffset(0x90)] public ulong Rbx;
            [FieldOffset(0x98)] public ulong Rsp;
            [FieldOffset(0xA0)] public ulong Rbp;
            [FieldOffset(0xA8)] public ulong Rsi;
            [FieldOffset(0xB0)] public ulong Rdi;
            [FieldOffset(0xF8)] public ulong Rip;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WaitForDebugEvent(ref DebugEvent value, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ContinueDebugEvent(int processId, int threadId, uint status);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DebugActiveProcessStop(int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetThreadContext(IntPtr thread, ref Context context);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetThreadContext(IntPtr thread, ref Context context);

        internal static void Start(IntPtr process, uint processId, TraceLog log)
        {
            int pid = unchecked((int)processId);
            Thread thread = new Thread(() => Loop(new Watch { Process = process, ProcessId = pid, Log = log }))
                { IsBackground = true, Name = "DialogTracer" };
            thread.Start();
        }

        private static void Loop(Watch watch)
        {
            int deadline = Environment.TickCount + WatchMilliseconds;
            try
            {
                watch.Log.Event("trace_started", new { pid = watch.ProcessId });
                while (Environment.TickCount < deadline)
                {
                    DebugEvent value = new DebugEvent();
                    if (!WaitForDebugEvent(ref value, PollMilliseconds))
                    {
                        if (Marshal.GetLastWin32Error() == 121 /* ERROR_SEM_TIMEOUT */) continue;
                        break;
                    }
                    bool finish = Handle(watch, value);
                    ContinueDebugEvent(value.ProcessId, value.ThreadId, ContinueStatus);
                    if (finish) break;
                }
            }
            catch (Exception error)
            {
                watch.Log.Event("trace_error", new { message = error.GetType().Name + ": " + error.Message });
            }
            finally
            {
                Detach(watch, "trace_done");
            }
        }

        private static bool Handle(Watch watch, DebugEvent value)
        {
            switch (value.Code)
            {
                case CREATE_PROCESS_DEBUG_EVENT:
                    watch.Threads[value.ThreadId] = value.CP_hThread;
                    watch.ImageBase = ToU64(value.CP_BaseOfImage);
                    watch.Modules[ToU64(value.CP_BaseOfDll)] = "main-module-base";
                    ClearDebugFlags(watch, value.CP_ThreadLocalBase);
                    watch.Log.Event("trace_create_process", new { pid = value.ProcessId, imageBase = Hex(watch.ImageBase) });
                    return false;
                case CREATE_THREAD_DEBUG_EVENT:
                    watch.Threads[value.ThreadId] = value.Ct_hThread;
                    return false;
                case EXIT_PROCESS_DEBUG_EVENT:
                    watch.Log.Event("trace_exit_process", new { });
                    return true;
                case LOAD_DLL_DEBUG_EVENT:
                {
                    ulong baseAddress = ToU64(value.Ld_BaseOfDll);
                    string name = ReadChildImageName(watch, value.Ld_ImageName, value.Ld_Unicode != 0);
                    watch.Modules[baseAddress] = string.IsNullOrEmpty(name) ? "unknown" : name;
                    if (name != null && name.EndsWith("user32.dll", StringComparison.OrdinalIgnoreCase))
                        InstallBreakpoints(watch, baseAddress, new[] { "MessageBoxW", "MessageBoxA", "DialogBoxParamW", "CreateDialogParamW" });
                    else if (name != null && name.EndsWith("kernel32.dll", StringComparison.OrdinalIgnoreCase))
                        InstallBreakpoints(watch, baseAddress, new[] { "TerminateProcess", "ExitProcess" });
                    else if (name != null && name.EndsWith("ntdll.dll", StringComparison.OrdinalIgnoreCase))
                        InstallBreakpoints(watch, baseAddress, new[] { "NtTerminateProcess" });
                    else if (name != null && name.EndsWith("wintrust.dll", StringComparison.OrdinalIgnoreCase))
                        InstallBreakpoints(watch, baseAddress, new[] { "WinVerifyTrust" });
                    if (!string.IsNullOrEmpty(name))
                        watch.Log.Event("trace_load_dll", new { baseAddress = Hex(baseAddress), name = name });
                    return false;
                }
                case EXCEPTION_DEBUG_EVENT:
                    return HandleException(watch, value);
                default:
                    return false;
            }
        }

        private static bool HandleException(Watch watch, DebugEvent value)
        {
            int code = value.Ex_Code;
            ulong address = ToU64(value.Ex_Address);
            if (code == EXCEPTION_BREAKPOINT && watch.Names.ContainsKey(address))
            {
                LogHit(watch, value.ThreadId, address);
                StepOver(watch, value.ThreadId, address);
                return false;
            }
            if (code == EXCEPTION_SINGLE_STEP && watch.Breakpoints.ContainsKey(address))
            {
                ArmBreakpoint(watch, address);
                return false;
            }
            // First system breakpoint and any obfuscation exceptions are passed to the child.
            return false;
        }

        private static void LogHit(Watch watch, int threadId, ulong address)
        {
            ulong returnAddress = 0;
            ulong[] stack = new ulong[8];
            Context context = new Context();
            context.ContextFlags = 0x00100003;
            IntPtr thread;
            if (watch.Threads.TryGetValue(threadId, out thread) && GetThreadContext(thread, ref context))
            {
                byte[] raw = Program.Read(watch.Process, ToI64(context.Rsp), 72);
                returnAddress = BitConverter.ToUInt64(raw, 0);
                for (int i = 0; i < 8; ++i)
                    stack[i] = BitConverter.ToUInt64(raw, 8 + i * 8);
            }
            watch.Log.Event("trace_hit", new {
                api = watch.Names[address],
                rip = Hex(address),
                returnAddress = Hex(returnAddress),
                returnRva = RvaOf(watch, returnAddress),
                stackRvas = StackRvas(watch, stack)
            });
            if (watch.Names[address] == "TerminateProcess" || watch.Names[address] == "NtTerminateProcess")
            {
                // Neutralize the termination: the first argument must be a valid process handle.
                if (!watch.Threads.ContainsKey(threadId)) return;
                Context context2 = new Context();
                context2.ContextFlags = 0x00100003;
                if (GetThreadContext(thread, ref context2))
                {
                    context2.Rcx = 0x1; // invalid as a process handle: the call will fail
                    SetThreadContext(thread, ref context2);
                    watch.Log.Event("trace_terminate_blocked", new { originalRcx = Hex(context.Rcx) });
                }
            }
        }

        private static object StackRvas(Watch watch, ulong[] stack)
        {
            List<object> result = new List<object>();
            foreach (ulong value in stack)
            {
                string rva = RvaOf(watch, value);
                if (rva != null) result.Add(rva);
            }
            return result;
        }

        private static string RvaOf(Watch watch, ulong address)
        {
            foreach (KeyValuePair<ulong, string> module in watch.Modules)
            {
                // The main image may be relocated; treat every recorded module base as a candidate.
                if (address >= module.Key && address < module.Key + 0x6000000)
                    return module.Value + "+0x" + (address - module.Key).ToString("x");
            }
            return null;
        }

        private static void StepOver(Watch watch, int threadId, ulong address)
        {
            RestoreBreakpoint(watch, address);
            IntPtr thread;
            if (!watch.Threads.TryGetValue(threadId, out thread)) return;
            Context context = new Context();
            context.ContextFlags = 0x00100003;
            if (!GetThreadContext(thread, ref context)) return;
            context.Rip = address; // re-execute the original instruction next
            context.EFlags |= 0x100;
            SetThreadContext(thread, ref context);
        }

        private static void InstallBreakpoints(Watch watch, ulong moduleBase, string[] functions)
        {
            foreach (string name in functions)
            {
                ulong address = FindChildExport(watch.Process, moduleBase, name);
                if (address == 0) continue;
                if (watch.Breakpoints.ContainsKey(address)) continue;
                byte[] original = Program.Read(watch.Process, ToI64(address), 1);
                watch.Breakpoints[address] = original[0];
                watch.Names[address] = name;
                ArmBreakpoint(watch, address);
            }
        }

        private static void ArmBreakpoint(Watch watch, ulong address)
        {
            WriteChild(watch.Process, new IntPtr(ToI64(address)), new byte[] { 0xCC });
        }

        private static void RestoreBreakpoint(Watch watch, ulong address)
        {
            byte original;
            if (!watch.Breakpoints.TryGetValue(address, out original)) return;
            WriteChild(watch.Process, new IntPtr(ToI64(address)), new[] { original });
        }

        private static void Detach(Watch watch, string eventName)
        {
            foreach (ulong address in new List<ulong>(watch.Breakpoints.Keys))
                RestoreBreakpoint(watch, address);
            try { DebugActiveProcessStop(watch.ProcessId); }
            catch (Exception error)
            {
                watch.Log.Event(eventName + "_detach_failed", new { message = error.Message });
                return;
            }
            watch.Log.Event(eventName, new { breakpoints = watch.Breakpoints.Count });
        }

        private static void ClearDebugFlags(Watch watch, IntPtr threadLocalBase)
        {
            byte[] pebPointer = Program.Read(watch.Process, ToI64(ToU64(threadLocalBase)) + 0x60, 8);
            long pebAddress = BitConverter.ToInt64(pebPointer, 0);
            if (pebAddress <= 0) return;
            WriteChild(watch.Process, new IntPtr(pebAddress + 2), new byte[] { 0 }); // BeingDebugged
            WriteChild(watch.Process, new IntPtr(pebAddress + 0xBC), new byte[] { 0, 0, 0, 0 }); // NtGlobalFlag
        }

        private static void WriteChild(IntPtr process, IntPtr address, byte[] data)
        {
            UIntPtr length = new UIntPtr((uint)data.Length);
            uint previous;
            if (!Native.VirtualProtectEx(process, address, length, 0x40, out previous))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "tracer VirtualProtectEx failed");
            try
            {
                UIntPtr written;
                if (!Native.WriteProcessMemory(process, address, data, length, out written))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "tracer WriteProcessMemory failed");
            }
            finally
            {
                uint ignored;
                Native.VirtualProtectEx(process, address, length, previous, out ignored);
            }
        }

        private static ulong FindChildExport(IntPtr process, ulong moduleBase, string name)
        {
            try
            {
                byte[] dos = Program.Read(process, ToI64(moduleBase), 0x40);
                int ntOffset = BitConverter.ToInt32(dos, 0x3c);
                byte[] header = Program.Read(process, ToI64(moduleBase) + ntOffset, 0x200);
                int optionalOffset = ntOffset + 0x18;
                // PE32+ export data directory is at optional header + 0x70.
                uint exportRva = BitConverter.ToUInt32(header, optionalOffset + 0x70);
                uint exportSize = BitConverter.ToUInt32(header, optionalOffset + 0x74);
                if (exportRva == 0 || exportSize == 0) return 0;
                ulong exportBase = moduleBase + exportRva;
                byte[] directory = Program.Read(process, ToI64(exportBase), 40);
                int numberOfNames = BitConverter.ToInt32(directory, 24);
                uint namesRva = BitConverter.ToUInt32(directory, 36);
                uint ordinalsRva = BitConverter.ToUInt32(directory, 40);
                uint functionsRva = BitConverter.ToUInt32(directory, 28);
                byte[] names = Program.Read(process, ToI64(moduleBase + namesRva), numberOfNames * 4);
                byte[] ordinals = Program.Read(process, ToI64(moduleBase + ordinalsRva), numberOfNames * 2);
                byte[] functions = Program.Read(process, ToI64(moduleBase + functionsRva), numberOfNames * 4);
                byte[] wanted = Encoding.ASCII.GetBytes(name);
                for (int i = 0; i < numberOfNames; ++i)
                {
                    uint nameRva = BitConverter.ToUInt32(names, i * 4);
                    if (nameRva == 0) continue;
                    byte[] text = Program.Read(process, ToI64(moduleBase + nameRva), 64);                    bool match = text.Length >= wanted.Length;
                    for (int j = 0; match && j < wanted.Length; ++j) match = text[j] == wanted[j];
                    if (match && text.Length > wanted.Length && text[wanted.Length] != 0) match = false;
                    if (!match) continue;
                    ushort ordinal = BitConverter.ToUInt16(ordinals, i * 2);
                    uint functionRva = BitConverter.ToUInt32(functions, ordinal * 4);
                    return moduleBase + functionRva;
                }
            }
            catch (Exception)
            {
                return 0;
            }
            return 0;
        }

        private static string ReadChildImageName(Watch watch, IntPtr pointerField, bool unicode)
        {
            if (pointerField == IntPtr.Zero || pointerField.ToInt64() <= 0x10000) return null;
            try
            {
                byte[] indirect = Program.Read(watch.Process, pointerField.ToInt64(), 8);
                long stringAddress = BitConverter.ToInt64(indirect, 0);
                if (stringAddress <= 0x10000) return null;
                byte[] header = Program.Read(watch.Process, stringAddress, 16);
                int length = BitConverter.ToUInt16(header, 0);
                long buffer = BitConverter.ToInt64(header, 8);
                if (length <= 0 || length > 1040 || buffer <= 0x10000) return null;
                byte[] raw = Program.Read(watch.Process, buffer, length);
                string name = unicode ? Encoding.Unicode.GetString(raw) : Encoding.ASCII.GetString(raw);
                int slash = name.LastIndexOf('\\');
                return slash >= 0 ? name.Substring(slash + 1) : name;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static ulong ToU64(IntPtr value) { return unchecked((ulong)value.ToInt64()); }
        private static long ToI64(ulong value) { return unchecked((long)value); }
        private static long ToI64(long value) { return value; }
        private static string Hex(ulong value) { return "0x" + value.ToString("x"); }
    }
}
