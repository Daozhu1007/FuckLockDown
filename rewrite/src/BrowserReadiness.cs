using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ProcessPolicyRewrite
{
    // The supported plan selects the visible CEF client, after native-window
    // construction and before the initial process-policy scan. The earlier
    // LOCKDOWNCHROME creation event is too soon to modify the original's code.
    internal static class BrowserReadiness
    {
        private delegate bool WindowCallback(IntPtr window, IntPtr value);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool EnumWindows(WindowCallback callback, IntPtr value);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr window, StringBuilder text, int count);
        [DllImport("ntdll.dll")]
        private static extern int NtSuspendProcess(IntPtr process);
        [DllImport("ntdll.dll")]
        private static extern int NtResumeProcess(IntPtr process);

        internal static void Wait(IntPtr process, uint processId, string windowClass,
                                  int timeoutMilliseconds, bool requireVisible, TraceLog log)
        {
            if (String.IsNullOrEmpty(windowClass)) throw new InvalidOperationException("No startup readiness class in the supported plan");
            if (timeoutMilliseconds == 0) timeoutMilliseconds = 60000;
            if (timeoutMilliseconds < 0 || timeoutMilliseconds > 300000)
                throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            Stopwatch elapsed = Stopwatch.StartNew();
            while (elapsed.ElapsedMilliseconds < timeoutMilliseconds)
            {
                uint wait = Native.WaitForSingleObject(process, 0);
                if (wait == 0)
                {
                    uint code;
                    if (!Native.GetExitCodeProcess(process, out code))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read browser startup exit code");
                    throw new InvalidOperationException("The original browser exited before startup readiness (exit " + code + ")");
                }
                if (wait != 0x102)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot observe browser startup");
                IntPtr found = IntPtr.Zero;
                bool enumerated = EnumWindows((window, value) => {
                    uint owner;
                    GetWindowThreadProcessId(window, out owner);
                    if (owner != processId) return true;
                    if (requireVisible && !IsWindowVisible(window)) return true;
                    StringBuilder name = new StringBuilder(256);
                    GetClassNameW(window, name, name.Capacity);
                    if (name.ToString() != windowClass) return true;
                    found = window;
                    return false;
                }, IntPtr.Zero);
                if (!enumerated && found == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot enumerate browser startup windows");
                if (found != IntPtr.Zero)
                {
                    log.Event("startup_ready", new { pid = processId, windowClass = windowClass,
                                                   requireVisible = requireVisible,
                                                   elapsedMilliseconds = elapsed.ElapsedMilliseconds });
                    return;
                }
                Thread.Sleep(10);
            }
            throw new TimeoutException("The original browser did not reach its supported startup stage within " +
                                       timeoutMilliseconds + " milliseconds");
        }

        internal static void Suspend(IntPtr process)
        {
            int status = NtSuspendProcess(process);
            if (status < 0) throw new InvalidOperationException("Cannot pause browser for policy activation (NTSTATUS 0x" + status.ToString("x8") + ")");
        }

        internal static void Resume(IntPtr process)
        {
            int status = NtResumeProcess(process);
            if (status < 0) throw new InvalidOperationException("Cannot resume browser after policy activation (NTSTATUS 0x" + status.ToString("x8") + ")");
        }
    }
}
