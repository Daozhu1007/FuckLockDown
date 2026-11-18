using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Fixture
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualProtect(IntPtr address, UIntPtr length, uint protection, out uint previous);
    [DllImport("kernel32.dll")]
    private static extern uint SetErrorMode(uint mode);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NativeFunction();

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WindowProcedure(IntPtr window, uint message, IntPtr first, IntPtr second);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        internal uint size, style;
        internal IntPtr procedure;
        internal int classBytes, windowBytes;
        internal IntPtr instance, icon, cursor, background;
        internal string menu, name;
        internal IntPtr smallIcon;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern ushort RegisterClassExW(ref WindowClass value);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr CreateWindowExW(uint extraStyle, string className, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern IntPtr DefWindowProcW(IntPtr window, uint message, IntPtr first, IntPtr second);
    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern bool UnregisterClassW(string className, IntPtr instance);
    private static readonly WindowProcedure Procedure = DefWindowProcW;

    private static IntPtr CreateReadinessWindow(string className, IntPtr instance)
    {
        WindowClass value = new WindowClass();
        value.size = (uint)Marshal.SizeOf(typeof(WindowClass));
        value.procedure = Marshal.GetFunctionPointerForDelegate(Procedure);
        value.instance = instance;
        value.name = className;
        if (RegisterClassExW(ref value) == 0)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Fixture window registration failed");
        IntPtr window = CreateWindowExW(0, className, "Harmless startup fixture", 0,
                                       0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (window == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Fixture window creation failed");
        return window;
    }

    [STAThread]
    private static int Main(string[] arguments)
    {
        SetErrorMode(0x8003);
        uint rva = 0;
        int expected = -1;
        string result = null;
        string readyClass = null, readySignal = null;
        int waitForPatchMilliseconds = 0, holdMilliseconds = 0, showAfterMilliseconds = -1;
        bool exitBeforeReady = false, changeBeforeReady = false;
        List<string> forwarded = new List<string>();
        for (int i = 0; i < arguments.Length; ++i)
        {
            if (arguments[i] == "--")
            {
                for (++i; i < arguments.Length; ++i) forwarded.Add(arguments[i]);
                break;
            }
            if (arguments[i] == "--native-rva") rva = Convert.ToUInt32(arguments[++i], 16);
            else if (arguments[i] == "--expected-return") expected = Int32.Parse(arguments[++i]);
            else if (arguments[i] == "--result") result = arguments[++i];
            else if (arguments[i] == "--ready-window") readyClass = arguments[++i];
            else if (arguments[i] == "--ready-signal") readySignal = arguments[++i];
            else if (arguments[i] == "--wait-for-patch-ms") waitForPatchMilliseconds = Int32.Parse(arguments[++i]);
            else if (arguments[i] == "--hold-ms") holdMilliseconds = Int32.Parse(arguments[++i]);
            else if (arguments[i] == "--show-after-ms") showAfterMilliseconds = Int32.Parse(arguments[++i]);
            else if (arguments[i] == "--exit-before-ready") exitBeforeReady = true;
            else if (arguments[i] == "--change-before-ready") changeBeforeReady = true;
            else throw new ArgumentException("Unexpected fixture argument");
        }
        if (rva == 0 || result == null || expected < 0) return 91;
        if (exitBeforeReady) return 93;
        IntPtr imageBase = Process.GetCurrentProcess().MainModule.BaseAddress;
        IntPtr code = new IntPtr(imageBase.ToInt64() + rva);
        byte[] actual = new byte[6];
        Marshal.Copy(code, actual, 0, actual.Length);
        if (actual[0] != 0xb8 || actual[2] != 0 || actual[3] != 0 || actual[4] != 0 || actual[5] != 0xc3)
            throw new InvalidDataException("Unexpected native fixture bytes: " + BitConverter.ToString(actual));
        uint oldProtection;
        // The CLR may remove execute access from IL/resource pages after initial image mapping.
        if (!VirtualProtect(code, new UIntPtr(6), 0x20, out oldProtection))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if (changeBeforeReady)
        {
            if (!VirtualProtect(code, new UIntPtr(6), 0x40, out oldProtection))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            Marshal.WriteByte(code, 1, 3);
            if (!VirtualProtect(code, new UIntPtr(6), 0x20, out oldProtection))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        IntPtr window = IntPtr.Zero;
        int valueBeforeShowing = -1;
        try
        {
            if (readyClass != null) window = CreateReadinessWindow(readyClass, imageBase);
            if (readySignal != null) File.WriteAllText(readySignal, Process.GetCurrentProcess().Id.ToString());
            if (window != IntPtr.Zero && showAfterMilliseconds >= 0)
            {
                Thread.Sleep(showAfterMilliseconds);
                valueBeforeShowing = Marshal.ReadByte(code, 1);
                ShowWindow(window, 4); // SW_SHOWNOACTIVATE: make the tiny fixture visible without taking focus.
            }
            if (holdMilliseconds > 0) Thread.Sleep(holdMilliseconds);
            Stopwatch elapsed = Stopwatch.StartNew();
            while (waitForPatchMilliseconds > 0 && Marshal.ReadByte(code, 1) != expected &&
                   elapsed.ElapsedMilliseconds < waitForPatchMilliseconds) Thread.Sleep(5);
            NativeFunction function = (NativeFunction)Marshal.GetDelegateForFunctionPointer(code, typeof(NativeFunction));
            int value = function();
            // The marker string sits right after the six native bytes. The launcher's
            // data neutre corrupts it in this process's memory before Main starts, so
            // reporting it here proves the neutralizer end to end (disk stays intact).
            byte[] markerBytes = new byte[Encoding.ASCII.GetBytes("NPG_NATIVE_FIXTURE_20261116").Length];
            Marshal.Copy(new IntPtr(code.ToInt64() + 6), markerBytes, 0, markerBytes.Length);
            string markerText = Encoding.ASCII.GetString(markerBytes);
            string json = new JavaScriptSerializer().Serialize(new {
                value = value, expected = expected, arguments = forwarded,
                markerText = markerText,
                readinessWindowCreated = window != IntPtr.Zero,
                readinessWindowVisible = window != IntPtr.Zero && IsWindowVisible(window),
                valueBeforeShowing = valueBeforeShowing,
                imageBase = "0x" + imageBase.ToInt64().ToString("x"), pid = Process.GetCurrentProcess().Id
            });
            using (FileStream stream = new FileStream(result, FileMode.CreateNew, FileAccess.Write))
            using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(json);
            return value == expected ? 0 : 92;
        }
        finally
        {
            if (window != IntPtr.Zero) { DestroyWindow(window); UnregisterClassW(readyClass, imageBase); }
        }
    }
}
