using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ProcessPolicyRewrite
{
    /// <summary>
    /// Neutralizes the encrypted string table's virtual-machine indicators after the
    /// child decrypts them. The table (a 557632-byte resource blob holding UI strings)
    /// contains short substrings ("QEMU", "VBOX", "XEN ", "Msft Virtual", "Red Hat VirtIO",
    /// registry value indicators, and device-name templates) that are matched against the
    /// machine's real hardware names. Rewriting those substrings in the child's memory,
    /// once the table appears there, makes the comparison miss any real hardware. Disk
    /// files are never touched, so file-integrity self-checks keep passing. Only
    /// equal-length replacements are used, so no structure or allocation changes.
    /// </summary>
#if NPG_TEST_HOOKS
    internal static class ResourceNeutralizer
    {
        private const long BlobBaseOffset = 0x3bc;
        internal const int WatchTimeoutMilliseconds = 180000;
        private const int PollMilliseconds = 400;
        internal const string BlobSignature = "The browser can't be used in virtual machine";
        private const long AnchorOffsetVbox = 0x23aa3;
        private const long AnchorOffsetQemu = 0x23aab;

        private static readonly Tuple<string, string>[] Pairs = BuildPairs();

        private static Tuple<string, string>[] BuildPairs()
        {
            // (original, equal-length replacement) for every virtualization indicator the
            // decrypted table contains. Sorted longest-first so longer names win over
            // their shorter substrings ("VMWare SVGA II" before "VMWare").
            Tuple<string, string>[] pairs =
            {
                Tuple.Create("VM Additions PC/AT Enhanced PS/2 Keyboard", "VM Additi0ns PC/AT Enhanced PS/2 Keyboard"),
                Tuple.Create("VMWare Accelerated AMD PCNet Adapter", "VMWar3 Accelerated AMD PCNet Adapter"),
                Tuple.Create("Parallels Mouse Synchronization Tool", "Paral1els Mouse Synchronization Tool"),
                Tuple.Create("VMWare Virtual IDE Hard Drive", "VMWar3 Virtual IDE Hard Drive"),
                Tuple.Create("VM Additions S3 Trio32/64", "VM Additi0ns S3 Trio32/64"),
                Tuple.Create("VMWare Pointing Device", "VMWare P0inting Device"),
                Tuple.Create("Parallels Video Driver", "Paral1els Video Driver"),
                Tuple.Create("Parallels Network Adapter", "Paral1els Network Adapter"),
                Tuple.Create("VM Additions PS/2 Port Mouse", "VM Additi0ns PS/2 Port Mouse"),
                Tuple.Create("VMWare SCSI Controller", "VMWar3 SCSI Controller"),
                Tuple.Create("PRL Virtual CD-ROM", "PRL Virtua1 CD-ROM"),
                Tuple.Create("VMWare SVGA II", "VMWare 5VGA II"),
                Tuple.Create("Red Hat VirtIO", "Red Hat VirtlO"),
                Tuple.Create("Sun VirtualBox", "Sun VirtualB0x"),
                Tuple.Create("Msft Virtual", "Msft Virtval"),
                Tuple.Create("Wine Adapter", "W1ne Adapter"),
                Tuple.Create("VMWare SVGA", "VMWare 5VGA"),
                Tuple.Create("Wine HID ", "W1ne HID "),
                Tuple.Create("Wine USB ", "W1ne USB "),
                Tuple.Create("Parallels", "Paral1els"),
                Tuple.Create("VMWare", "VMWar3"),
                Tuple.Create("VRTUAL", "VRTUA1"),
                Tuple.Create("VBOX", "VBOY"),
                Tuple.Create("QEMU", "QEMV"),
                Tuple.Create("XEN ", "YEN "),
                Tuple.Create("PRLS", "PRLT"),
                Tuple.Create("WINE", "W1NE"),
            };
            return pairs;
        }

        internal static void StartWatch(IntPtr process, TraceLog log)
        {
            Thread watcher = new Thread(() => Watch(process, log)) { IsBackground = true, Name = "ResourceNeutralizer" };
            watcher.Start();
        }

        private static void Watch(IntPtr process, TraceLog log)
        {
            byte[] signature = Encoding.ASCII.GetBytes(BlobSignature);
            int deadline = Environment.TickCount + WatchTimeoutMilliseconds;
            HashSet<long> interestingRegions = new HashSet<long>();
            int consecutiveScanFailures = 0;
            int totalApplied = 0;
            try
            {
                // The table may be decrypted more than once (per-consumer copies), may be
                // re-decrypted into the same address, or may still be partially encrypted
                // when first seen. The watcher therefore re-verifies every known copy for
                // the whole watch window and rewrites any entry that is back to its
                // original text. Reads that fail transiently (region freed between query
                // and read) are retried; only repeated failures end the watch early.
                while (Environment.TickCount < deadline)
                {
                    Thread.Sleep(PollMilliseconds);
                    List<object> applied = new List<object>(), seen = new List<object>();
                    bool anyRegionRead = false;
                    try
                    {
                        anyRegionRead = ScanPass(process, signature, interestingRegions, applied, seen);
                    }
                    catch (Win32Exception)
                    {
                        // Surface-level failure for this whole pass; the next poll retries.
                    }
                    if (anyRegionRead) consecutiveScanFailures = 0; else if (++consecutiveScanFailures >= 8) break;
                    if (applied.Count > 0)
                    {
                        totalApplied += applied.Count;
                        log.Event("resource_neutralized", new { regions = interestingRegions.Count, applied = applied.Count, totalApplied = totalApplied });
                    }
                    else if (seen.Count > 0)
                    {
                        log.Event("resource_seen", new { regions = seen });
                    }
                }
                log.Event("resource_neutralize_done", new { totalApplied = totalApplied, regions = interestingRegions.Count });
            }
            catch (Exception error)
            {
                // The child may exit or restrict memory access at any moment; this watcher is advisory.
                try { log.Event("resource_neutralize_stopped", new { message = error.GetType().Name + ": " + error.Message, totalApplied = totalApplied }); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        /// <summary>True once the signature sentence exists anywhere in readable private memory.</summary>
        internal static bool SignaturePresent(IntPtr process, byte[] signature)
        {
            long address = 0x10000;
            long maximum = 0x7fffffffL;
            while (address < maximum)
            {
                Native.MemoryBasicInformation info;
                if (Native.VirtualQueryEx(process, new IntPtr(address), out info,
                                          (UIntPtr)Marshal.SizeOf(typeof(Native.MemoryBasicInformation))) == IntPtr.Zero)
                    break;
                long regionSize = info.RegionSize.ToInt64();
                if (regionSize <= 0) break;
                long next = address + regionSize;
                bool readable = info.State == 0x1000 && info.Type == 0x20000 &&
                                (info.Protect & 0x100) == 0 && (info.Protect & 0xff) != 0x01 &&
                                (info.Protect & 0xff) != 0x00;
                if (readable && regionSize <= 0x4000000)
                {
                    try
                    {
                        if (RegionContains(process, address, regionSize, signature)) return true;
                    }
                    catch (Win32Exception) { }
                }
                address = next;
            }
            return false;
        }

        /// <summary>
        /// One full memory sweep. Regions that contain the signature sentence are the
        /// decrypted string resource (the runtime pool is repacked, so offsets differ
        /// from the on-disk blob); every poll those regions are re-searched for the
        /// indicator strings and any original occurrence is rewritten in place.
        /// Returns true when at least one region could be read.
        /// </summary>
        private static bool ScanPass(IntPtr process, byte[] signature, HashSet<long> interestingRegions,
                                     List<object> applied, List<object> seen)
        {
            bool anyRead = false;
            long address = 0x10000;
            long maximum = 0x7fffffffL;
            while (address < maximum)
            {
                Native.MemoryBasicInformation info;
                if (Native.VirtualQueryEx(process, new IntPtr(address), out info,
                                          (UIntPtr)Marshal.SizeOf(typeof(Native.MemoryBasicInformation))) == IntPtr.Zero)
                    break;
                long regionSize = info.RegionSize.ToInt64();
                if (regionSize <= 0) break;
                long next = address + regionSize;
                bool readable = info.State == 0x1000 && info.Type == 0x20000 &&
                                (info.Protect & 0x100) == 0 && (info.Protect & 0xff) != 0x01 &&
                                (info.Protect & 0xff) != 0x00;
                if (readable && regionSize <= 0x4000000) // skip huge reservations
                {
                    bool alreadyInteresting = interestingRegions.Contains(address);
                    try
                    {
                        bool hasSignature = alreadyInteresting || RegionContains(process, address, regionSize, signature);
                        if (hasSignature)
                        {
                            if (!alreadyInteresting)
                            {
                                interestingRegions.Add(address);
                                seen.Add("0x" + address.ToString("x"));
                            }
                            NeutralizeRegion(process, address, regionSize, applied);
                            anyRead = true;
                        }
                        else
                        {
                            anyRead = anyRead || RegionReadable(process, address, regionSize);
                        }
                    }
                    catch (Win32Exception)
                    {
                        // Region freed or protected between query and read: skip it.
                    }
                }
                address = next;
            }
            return anyRead;
        }

        private static bool RegionReadable(IntPtr process, long address, long regionSize)
        {
            try
            {
                Program.Read(process, address, 16);
                return true;
            }
            catch (Win32Exception)
            {
                return false;
            }
        }

        private static bool RegionContains(IntPtr process, long address, long regionSize, byte[] signature)
        {
            const long chunkSize = 0x800000; // 8 MiB per ReadProcessMemory call
            const int overlap = 512;
            for (long offset = 0; offset < regionSize; offset += chunkSize)
            {
                long take = Math.Min(chunkSize + overlap, regionSize - offset);
                if (take < signature.Length) break;
                byte[] buffer = Program.Read(process, address + offset, (int)take);
                if (FindAll(buffer, signature, 0).Count > 0) return true;
            }
            return false;
        }

        private static void NeutralizeRegion(IntPtr process, long address, long regionSize, List<object> applied)
        {
            const long chunkSize = 0x800000;
            const int overlap = 512;
            for (long offset = 0; offset < regionSize; offset += chunkSize)
            {
                long take = Math.Min(chunkSize + overlap, regionSize - offset);
                if (take < 16) break;
                byte[] buffer;
                try
                {
                    buffer = Program.Read(process, address + offset, (int)take);
                }
                catch (Win32Exception)
                {
                    continue;
                }
                NeutralizeBuffer(process, address + offset, buffer, applied);
            }
        }

        private static void NeutralizeBuffer(IntPtr process, long chunkAddress, byte[] buffer, List<object> applied)
        {
            List<long[]> written = new List<long[]>(); // [start, end) intervals inside the chunk
            foreach (Tuple<string, string> pair in Pairs)
            {
                byte[] needle = Encoding.ASCII.GetBytes(pair.Item1);
                byte[] replacement = Encoding.ASCII.GetBytes(pair.Item2);
                int searchFrom = 0;
                int index;
                while ((index = IndexOf(buffer, needle, searchFrom)) >= 0)
                {
                    searchFrom = index + needle.Length;
                    bool overlaps = false;
                    foreach (long[] interval in written)
                    {
                        if (index < interval[1] && interval[0] < index + needle.Length) { overlaps = true; break; }
                    }
                    if (overlaps) continue;
                    long target = chunkAddress + index;
                    WriteChildMemory(process, target, replacement);
                    if (Program.Equal(Program.Read(process, target, replacement.Length), replacement))
                        applied.Add("0x" + target.ToString("x") + ":" + pair.Item1);
                    written.Add(new long[] { index, index + needle.Length });
                }
            }
        }

        private static List<long> FindAll(byte[] haystack, byte[] needle, long relativeBase)
        {
            List<long> found = new List<long>();
            int searchFrom = 0;
            int index;
            while ((index = IndexOf(haystack, needle, searchFrom)) >= 0)
            {
                found.Add(relativeBase + index);
                searchFrom = index + needle.Length;
            }
            return found;
        }

        private static int IndexOf(byte[] haystack, byte[] needle, int start)
        {
            int limit = haystack.Length - needle.Length;
            for (int i = start; i <= limit; ++i)
            {
                if (haystack[i] != needle[0]) continue;
                bool match = true;
                for (int j = 1; j < needle.Length; ++j)
                {
                    if (haystack[i + j] != needle[j]) { match = false; break; }
                }
                if (match) return i;
            }
            return -1;
        }

        private static void WriteChildMemory(IntPtr process, long address, byte[] replacement)
        {
            IntPtr location = new IntPtr(address);
            UIntPtr length = new UIntPtr((uint)replacement.Length);
            uint previous;
            if (!Native.VirtualProtectEx(process, location, length, 0x40, out previous))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot make string page writable");
            try
            {
                UIntPtr written;
                if (!Native.WriteProcessMemory(process, location, replacement, length, out written))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed for string patch");
                if (!Native.FlushInstructionCache(process, location, length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushInstructionCache failed for string patch");
            }
            finally
            {
                uint ignored;
                Native.VirtualProtectEx(process, location, length, previous, out ignored);
            }
        }
    }

#endif

    public sealed class Patch
    {
        public string id { get; set; }
        public string rva { get; set; }
        public string expected { get; set; }
        public string replacement { get; set; }
        public string rationale { get; set; }
    }

    public sealed class Plan
    {
        public int schemaVersion { get; set; }
        public string targetName { get; set; }
        public string targetSha256 { get; set; }
        public string status { get; set; }
        public string readinessWindowClass { get; set; }
        public bool readinessWindowVisible { get; set; }
        public int readinessTimeoutMilliseconds { get; set; }
        public string activation { get; set; }
        public List<Patch> patches { get; set; }
    }

    internal sealed class Options
    {
        internal bool Check;
        internal bool NoUi;
        internal bool Help;
#if NPG_TEST_HOOKS
        internal bool FailAfterRemoteValidation;
        internal string PatchMode;
        internal bool NeutralizeVm;
#endif
        internal string Target;
        internal string Log;
        internal readonly List<string> Forward = new List<string>();

        internal static Options Parse(string[] arguments)
        {
            Options value = new Options();
            for (int i = 0; i < arguments.Length; ++i)
            {
                string item = arguments[i];
                if (item == "--")
                {
                    for (++i; i < arguments.Length; ++i) value.Forward.Add(arguments[i]);
                    break;
                }
                if (item == "--check") value.Check = true;
#if NPG_TEST_HOOKS
                else if (item == "--test-fail-after-create") value.FailAfterRemoteValidation = true;
                else if (item == "--patch-mode")
                {
                    if (++i == arguments.Length) throw new ArgumentException("Missing value for --patch-mode");
                    value.PatchMode = arguments[i];
                    if (value.PatchMode != "immediate" && value.PatchMode != "none" && value.PatchMode != "deferred"
                        && value.PatchMode != "delayed" && value.PatchMode != "startup" && value.PatchMode != "trace")
                        throw new ArgumentException("Unknown experimental patch mode: " + value.PatchMode);
                }
                else if (item == "--lab-neutralize-vm") value.NeutralizeVm = true;
#endif
                else if (item == "--no-ui") value.NoUi = true;
                else if (item == "--help" || item == "-h") value.Help = true;
                else if (item == "--exe" || item == "--log")
                {
                    if (++i == arguments.Length) throw new ArgumentException("Missing value for " + item);
                    if (item == "--exe") value.Target = arguments[i];
                    else value.Log = arguments[i];
                }
                else value.Forward.Add(item);
            }
            return value;
        }
    }

    internal sealed class TraceLog : IDisposable
    {
        private readonly StreamWriter writer;
        private readonly object gate = new object();
        private bool writeFailed;
        internal readonly string PathName;
        internal TraceLog(string path)
        {
            if (String.IsNullOrEmpty(path))
                path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                    "ProcessPolicyRewrite", "logs", Guid.NewGuid().ToString("N") + ".jsonl");
            PathName = Path.GetFullPath(path);
            Directory.CreateDirectory(Path.GetDirectoryName(PathName));
            writer = new StreamWriter(new FileStream(PathName, FileMode.CreateNew, FileAccess.Write, FileShare.Read),
                                      new UTF8Encoding(false));
            writer.AutoFlush = true;
        }
        internal void Event(string kind, object value)
        {
            if (writeFailed) return;
            try
            {
                lock (gate)
                {
                    if (writeFailed) return;
                    writer.WriteLine(new JavaScriptSerializer().Serialize(new {
                        time = DateTimeOffset.UtcNow.ToString("o"), eventType = kind, data = value
                    }));
                }
            }
            catch (IOException error) { LogFailure(error); }
            catch (UnauthorizedAccessException error) { LogFailure(error); }
        }
        private void LogFailure(Exception error)
        {
            writeFailed = true;
            try { Console.Error.WriteLine("Diagnostic log unavailable: " + error.Message); }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
        public void Dispose()
        {
            try { writer.Dispose(); }
            catch (IOException error) { LogFailure(error); }
            catch (UnauthorizedAccessException error) { LogFailure(error); }
        }
    }

    internal sealed class PeImage
    {
        internal readonly byte[] Bytes;
        internal readonly int NtOffset;
        internal readonly uint ImageSize;
        private readonly int sectionTable;
        private readonly ushort sectionCount;

        internal PeImage(byte[] bytes)
        {
            Bytes = bytes;
            Require(bytes.Length >= 0x100 && bytes[0] == 0x4d && bytes[1] == 0x5a, "Invalid DOS header");
            NtOffset = BitConverter.ToInt32(bytes, 0x3c);
            Require(NtOffset >= 0x40 && NtOffset <= bytes.Length - 0x108, "Invalid PE header position");
            Require(BitConverter.ToUInt32(bytes, NtOffset) == 0x4550, "Invalid PE signature");
            Require(BitConverter.ToUInt16(bytes, NtOffset + 4) == 0x8664, "Only AMD64 targets are supported");
            Require(BitConverter.ToUInt16(bytes, NtOffset + 24) == 0x20b, "Expected PE32+");
            ImageSize = BitConverter.ToUInt32(bytes, NtOffset + 24 + 56);
            sectionCount = BitConverter.ToUInt16(bytes, NtOffset + 6);
            sectionTable = NtOffset + 24 + BitConverter.ToUInt16(bytes, NtOffset + 20);
            Require(sectionCount > 0 && sectionTable <= bytes.Length - sectionCount * 40, "Invalid section table");
        }

        internal int CodeOffset(uint rva, int count)
        {
            Require(count > 0 && count <= 32 && (ulong)rva + (uint)count <= ImageSize, "Invalid patch extent");
            for (int i = 0; i < sectionCount; ++i)
            {
                int entry = sectionTable + i * 40;
                uint start = BitConverter.ToUInt32(Bytes, entry + 12);
                uint rawSize = BitConverter.ToUInt32(Bytes, entry + 16);
                uint rawOffset = BitConverter.ToUInt32(Bytes, entry + 20);
                uint flags = BitConverter.ToUInt32(Bytes, entry + 36);
                if (rva < start || (ulong)rva + (uint)count > (ulong)start + rawSize) continue;
                Require((flags & 0x20000000) != 0, "Patch must be in a file-backed executable section");
                ulong position = (ulong)rawOffset + rva - start;
                Require(position + (uint)count <= (ulong)Bytes.Length, "Truncated section");
                return checked((int)position);
            }
            throw new InvalidDataException("Patch RVA has no file-backed executable mapping");
        }

        internal static void Require(bool value, string message)
        {
            if (!value) throw new InvalidDataException(message);
        }
    }

    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct StartupInfo
        {
            internal int cb;
            internal string reserved, desktop, title;
            internal uint x, y, width, height, charsX, charsY, fill, flags;
            internal ushort showWindow, reservedSize;
            internal IntPtr reservedData, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct ProcessInfo
        {
            internal IntPtr process, thread;
            internal uint processId, threadId;
        }
        [StructLayout(LayoutKind.Sequential)]
        internal struct BasicInfo
        {
            internal IntPtr reserved1, peb, reserved2, reserved3, processId, reserved4;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CreateProcessW(string application, StringBuilder command, IntPtr pa, IntPtr ta,
            bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfo startup, out ProcessInfo info);
        [DllImport("ntdll.dll")]
        internal static extern int NtQueryInformationProcess(IntPtr process, int kind, out BasicInfo value,
            uint length, out uint returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr size, out UIntPtr read);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] data, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool VirtualProtectEx(IntPtr process, IntPtr address, UIntPtr size, uint protect, out uint oldProtect);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool FlushInstructionCache(IntPtr process, IntPtr address, UIntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")]
        internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr VirtualQueryEx(IntPtr process, IntPtr address, out MemoryBasicInformation info, UIntPtr length);

        [StructLayout(LayoutKind.Sequential)]
        internal struct MemoryBasicInformation
        {
            public IntPtr BaseAddress;
            public IntPtr AllocationBase;
            public uint AllocationProtect;
            private uint padding1;
            public IntPtr RegionSize;
            public uint State;
            public uint Protect;
            public uint Type;
            private uint padding2;
        }
    }

    internal static class Program
    {
        internal static string Quote(string value)
        {
            // Windows CommandLineToArgvW/CRT escaping. No command shell is used.
            StringBuilder result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\') { ++backslashes; continue; }
                if (character == '"') result.Append('\\', backslashes * 2 + 1);
                else result.Append('\\', backslashes);
                result.Append(character);
                backslashes = 0;
            }
            result.Append('\\', backslashes * 2);
            return result.Append('"').ToString();
        }

        private static byte[] Hex(string value)
        {
            string compact = value.Replace(" ", "").Replace("\r", "").Replace("\n", "");
            PeImage.Require(compact.Length > 0 && compact.Length % 2 == 0, "Invalid hex bytes");
            byte[] result = new byte[compact.Length / 2];
            for (int i = 0; i < result.Length; ++i)
                result[i] = Byte.Parse(compact.Substring(i * 2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return result;
        }
        private static uint Rva(Patch value)
        {
            return UInt32.Parse(value.rva.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? value.rva.Substring(2) : value.rva,
                                NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        }
        internal static bool Equal(byte[] first, byte[] second)
        {
            if (first.Length != second.Length) return false;
            for (int i = 0; i < first.Length; ++i) if (first[i] != second[i]) return false;
            return true;
        }
        private static string Hash(byte[] bytes)
        {
            using (SHA256 sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        internal static byte[] Read(IntPtr process, long address, int count)
        {
            byte[] bytes = new byte[count];
            UIntPtr read;
            if (!Native.ReadProcessMemory(process, new IntPtr(address), bytes, new UIntPtr((uint)count), out read))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadProcessMemory failed");
            PeImage.Require(read.ToUInt64() == (ulong)count, "Partial process memory read");
            return bytes;
        }
        private static Plan LoadPlan()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("PatchPlan.json"))
            {
                PeImage.Require(stream != null, "Embedded patch plan is missing");
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                    return new JavaScriptSerializer().Deserialize<Plan>(reader.ReadToEnd());
            }
        }

        private static PeImage Preflight(Plan plan, string path, byte[] source)
        {
            PeImage.Require(plan.schemaVersion == 1 && plan.patches != null && plan.patches.Count > 0, "Invalid patch plan");
            string activation = String.IsNullOrEmpty(plan.activation) ? "code-patches" : plan.activation;
            PeImage.Require(activation == "code-patches" || activation == "policy-data",
                            "Unknown plan activation mode: " + activation);
            PeImage.Require(plan.readinessTimeoutMilliseconds >= 0 && plan.readinessTimeoutMilliseconds <= 300000,
                            "Startup readiness timeout must be between 0 and 300000 milliseconds");
            PeImage.Require(String.Equals(Path.GetFileName(path), plan.targetName, StringComparison.OrdinalIgnoreCase),
                            "Unexpected target filename");
            PeImage.Require(String.Equals(Hash(source), plan.targetSha256, StringComparison.OrdinalIgnoreCase),
                            "Target SHA-256 does not match this exact supported build");
            PeImage image = new PeImage(source);
            List<Tuple<uint, uint>> ranges = new List<Tuple<uint, uint>>();
            HashSet<string> ids = new HashSet<string>();
            foreach (Patch patch in plan.patches)
            {
                PeImage.Require(!String.IsNullOrEmpty(patch.id) && ids.Add(patch.id), "Invalid or repeated patch ID");
                byte[] expected = Hex(patch.expected), replacement = Hex(patch.replacement);
                PeImage.Require(expected.Length == replacement.Length, "Patch changes instruction extent");
                uint start = Rva(patch), end = checked(start + (uint)expected.Length);
                foreach (Tuple<uint, uint> range in ranges)
                    PeImage.Require(end <= range.Item1 || start >= range.Item2, "Overlapping patches");
                ranges.Add(Tuple.Create(start, end));
                int offset = image.CodeOffset(start, expected.Length);
                byte[] actual = new byte[expected.Length];
                Array.Copy(source, offset, actual, 0, actual.Length);
                PeImage.Require(Equal(actual, expected), "Source bytes do not match patch " + patch.id);
            }
            return image;
        }

        private static int Run(Plan plan, Options options, TraceLog log)
        {
            string path = TargetDiscovery.Resolve(options.Target, plan.targetName, plan.targetSha256);
            Native.ProcessInfo child = new Native.ProcessInfo();
            bool activated = false;
            try
            {
                // The source file handle is closed before the child is even created: holding
                // it for the whole browser lifetime makes the browser's own file checks see
                // an external reader for hours and fail its authorization logic.
                byte[] source = File.ReadAllBytes(path);
                PeImage image = Preflight(plan, path, source);
                log.Event("preflight", new { sha256 = plan.targetSha256, patchCount = plan.patches.Count,
                    status = plan.status, checkOnly = options.Check });
                if (options.Check)
                {
                    Console.WriteLine(new JavaScriptSerializer().Serialize(new {
                        verified = true, sha256 = plan.targetSha256, patchCount = plan.patches.Count, status = plan.status
                    }));
                    return 0;
                }

                StringBuilder command = new StringBuilder(Quote(path));
                foreach (string argument in options.Forward) command.Append(" ").Append(Quote(argument));
                Native.StartupInfo startup = new Native.StartupInfo();
                startup.cb = Marshal.SizeOf(typeof(Native.StartupInfo));
                uint createFlags = 0x4;
#if NPG_TEST_HOOKS
                if (options.PatchMode == "trace") createFlags |= 0x2;
#endif
                if (!Native.CreateProcessW(path, command, IntPtr.Zero, IntPtr.Zero, false, createFlags,
                                           IntPtr.Zero, Path.GetDirectoryName(path), ref startup, out child))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 740) throw new Win32Exception(error, "The original browser requires administrator privileges; run this launcher as administrator");
                    throw new Win32Exception(error, "CreateProcessW failed");
                }
                try
                {
                    log.Event("child_created_suspended", new { pid = child.processId });
                    Native.BasicInfo basic;
                    uint returned;
                    int status = Native.NtQueryInformationProcess(child.process, 0, out basic,
                        (uint)Marshal.SizeOf(typeof(Native.BasicInfo)), out returned);
                    PeImage.Require(status >= 0 && basic.peb != IntPtr.Zero, "Cannot locate the new process PEB");
                    // AMD64 PEB ImageBaseAddress offset; validate the remote PE before using any patch RVA.
                    long imageBase = BitConverter.ToInt64(Read(child.process, basic.peb.ToInt64() + 0x10, 8), 0);
                    byte[] dos = Read(child.process, imageBase, 0x40);
                    PeImage.Require(dos[0] == 0x4d && dos[1] == 0x5a && BitConverter.ToInt32(dos, 0x3c) == image.NtOffset,
                                    "Unexpected remote DOS header");
                    byte[] header = Read(child.process, imageBase + image.NtOffset, 0x80);
                    PeImage.Require(BitConverter.ToUInt32(header, 0) == 0x4550 && BitConverter.ToUInt16(header, 4) == 0x8664 &&
                                    BitConverter.ToUInt32(header, 24 + 56) == image.ImageSize, "Unexpected remote PE identity");
                    // Validate all remote bytes before changing any page. For the
                    // heap-table activation this doubles as a live identity check.
                    foreach (Patch patch in plan.patches)
                        PeImage.Require(Equal(Read(child.process, imageBase + Rva(patch), Hex(patch.expected).Length), Hex(patch.expected)),
                                        "Remote bytes do not match patch " + patch.id);
                    string activation = String.IsNullOrEmpty(plan.activation) ? "code-patches" : plan.activation;
                    PeImage.Require(activation == "code-patches" || activation == "policy-data",
                                    "Unknown plan activation mode: " + activation);
                    if (activation == "policy-data")
                    {
                        // Emptying the heap rule table needs no code modification and no
                        // window marker: the decrypted table itself is the readiness signal,
                        // so the launcher never races the original's code-integrity checks.
                        log.Event("child_initializing", new { pid = child.processId, activation = activation });
                        PeImage.Require(Native.ResumeThread(child.thread) == 1, "Unexpected primary-thread suspend count");
                        PolicyData.Activate(child.process, imageBase, log);
                    }
                    else
                    {
#if NPG_TEST_HOOKS
                    if (options.FailAfterRemoteValidation)
                        throw new InvalidOperationException("Injected fixture failure after remote validation");
                    string patchMode = options.PatchMode;
#else
                    string patchMode = null;
#endif
                    if (String.IsNullOrEmpty(patchMode))
                        patchMode = String.IsNullOrEmpty(plan.readinessWindowClass) ? "immediate" : "startup";
                    if (patchMode == "immediate" || patchMode == "trace")
                        ApplyCodePatches(child.process, imageBase, plan, log);
                    uint suspendCount = Native.ResumeThread(child.thread);
                    PeImage.Require(suspendCount == 1, "Unexpected primary-thread suspend count");
                    if (patchMode == "startup")
                    {
                        log.Event("child_initializing", new { pid = child.processId });
                        BrowserReadiness.Wait(child.process, child.processId, plan.readinessWindowClass,
                                              plan.readinessTimeoutMilliseconds, plan.readinessWindowVisible, log);
                        BrowserReadiness.Suspend(child.process);
                        log.Event("child_suspended_for_policy", new { pid = child.processId });
                        try
                        {
                            ApplyCodePatches(child.process, imageBase, plan, log);
                        }
                        finally
                        {
                            BrowserReadiness.Resume(child.process);
                        }
                    }
                    log.Event("child_resumed", new { pid = child.processId });
#if NPG_TEST_HOOKS
                    if (patchMode == "deferred" || patchMode == "delayed")
                        DeferredPatchStart(child.process, plan, log, patchMode == "delayed" ? 10000 : 0);
                    if (patchMode == "trace")
                        Tracer.Start(child.process, child.processId, log);
                    if (options.NeutralizeVm) ResourceNeutralizer.StartWatch(child.process, log);
#endif
                    }
                    activated = true;
                }
                finally
                {
                    // A failed startup must not leave our unmodified or partially modified
                    // browser running a process-closing policy. Only our own new PID is touched.
                    if (!activated && child.process != IntPtr.Zero)
                    {
                        bool stopped = Native.TerminateProcess(child.process, 0xE0000001);
                        int stopError = stopped ? 0 : Marshal.GetLastWin32Error();
                        uint cleanupWait = Native.WaitForSingleObject(child.process, 5000);
                        log.Event("failed_child_cleanup", new { pid = child.processId, stopped = stopped, wait = cleanupWait, error = stopError });
                        if (cleanupWait != 0)
                            throw new InvalidOperationException("Incomplete browser child PID " + child.processId +
                                " could not be confirmed terminated (Win32 " + stopError + ", wait " + cleanupWait + ")");
                    }
                    if (child.thread != IntPtr.Zero) { Native.CloseHandle(child.thread); child.thread = IntPtr.Zero; }
                    if (!activated && child.process != IntPtr.Zero) { Native.CloseHandle(child.process); child.process = IntPtr.Zero; }
                }
                uint wait = Native.WaitForSingleObject(child.process, 0xFFFFFFFF);
                PeImage.Require(wait == 0, "Waiting for the browser failed");
                uint code;
                if (!Native.GetExitCodeProcess(child.process, out code))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
                log.Event("child_exit", new { pid = child.processId, code = code });
                return unchecked((int)code);
            }
            finally
            {
                if (child.thread != IntPtr.Zero) Native.CloseHandle(child.thread);
                if (child.process != IntPtr.Zero) Native.CloseHandle(child.process);
            }
        }

#if NPG_TEST_HOOKS
        /// <summary>
        /// Experiment only: wait until the child decrypts its string table, then apply the
        /// code patches. This distinguishes a one-shot early integrity scan from a
        /// continuous one, and measures how long the unpatched startup survives.
        /// </summary>
        internal static void DeferredPatchStart(IntPtr process, Plan plan, TraceLog log, int delayMilliseconds)
        {
            byte[] signature = Encoding.ASCII.GetBytes(ResourceNeutralizer.BlobSignature);
            Thread worker = new Thread(() =>
            {
                int deadline = Environment.TickCount + ResourceNeutralizer.WatchTimeoutMilliseconds;
                bool applied = false;
                try
                {
                    if (delayMilliseconds > 0)
                    {
                        Thread.Sleep(delayMilliseconds);
                        log.Event("deferred_delay_elapsed", new { delayMilliseconds = delayMilliseconds });
                    }
                    while (Environment.TickCount < deadline && !applied)
                    {
                        Thread.Sleep(200);
                        if (!ResourceNeutralizer.SignaturePresent(process, signature)) continue;
                        Native.BasicInfo basic;
                        uint returned;
                        int status = Native.NtQueryInformationProcess(process, 0, out basic,
                            (uint)Marshal.SizeOf(typeof(Native.BasicInfo)), out returned);
                        PeImage.Require(status >= 0 && basic.peb != IntPtr.Zero, "Deferred: cannot locate the PEB");
                        long imageBase = BitConverter.ToInt64(Read(process, basic.peb.ToInt64() + 0x10, 8), 0);
                        log.Event("deferred_patch_begin", new { });
                        ApplyCodePatches(process, imageBase, plan, log);
                        applied = true;
                    }
                }
                catch (Exception error)
                {
                    log.Event("deferred_patch_stopped", new { message = error.GetType().Name + ": " + error.Message });
                    return;
                }
                if (!applied) log.Event("deferred_patch_timeout", new { });
            }) { IsBackground = true, Name = "DeferredPatcher" };
            worker.Start();
        }
#endif

        internal static void ApplyCodePatches(IntPtr process, long imageBase, Plan plan, TraceLog log)
        {
            foreach (Patch patch in plan.patches)
                PeImage.Require(Equal(Read(process, imageBase + Rva(patch), Hex(patch.expected).Length), Hex(patch.expected)),
                                "Remote bytes do not match patch " + patch.id);
            foreach (Patch patch in plan.patches)
            {
                byte[] replacement = Hex(patch.replacement);
                IntPtr address = new IntPtr(imageBase + Rva(patch));
                UIntPtr length = new UIntPtr((uint)replacement.Length);
                uint previous;
                if (!Native.VirtualProtectEx(process, address, length, 0x40, out previous))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot make patch page writable");
                try
                {
                    UIntPtr written;
                    if (!Native.WriteProcessMemory(process, address, replacement, length, out written))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed");
                    PeImage.Require(written.ToUInt64() == (ulong)replacement.Length, "Partial process memory write");
                    PeImage.Require(Equal(Read(process, address.ToInt64(), replacement.Length), replacement), "Patch readback mismatch");
                }
                finally
                {
                    uint ignored;
                    if (!Native.VirtualProtectEx(process, address, length, previous, out ignored))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot restore original page protection");
                }
                if (!Native.FlushInstructionCache(process, address, length))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushInstructionCache failed");
                log.Event("patch_verified", new { id = patch.id, rva = patch.rva });
            }
        }

        [STAThread]
        private static int Main(string[] arguments)
        {
            Options options = null;
            TraceLog log = null;
            try
            {
                if (IntPtr.Size != 8) throw new PlatformNotSupportedException("Use the AMD64 build");
                options = Options.Parse(arguments);
#if CHECK_ONLY
                options.Check = true;
                options.NoUi = true;
#endif
                if (options.Help)
                {
                    Console.WriteLine("ProcessPolicyLauncher [--check] [--exe path] [--log new-file] [--no-ui] [-- browser arguments]");
                    return 0;
                }
                log = new TraceLog(options.Log);
                return Run(LoadPlan(), options, log);
            }
            catch (Exception error)
            {
                string message = error.GetType().Name + ": " + error.Message;
                if (log != null) log.Event("error", new { message = message });
                Console.Error.WriteLine(message);
                if (options != null && !options.NoUi && !options.Check)
                    System.Windows.Forms.MessageBox.Show(message, "Process policy rewrite", System.Windows.Forms.MessageBoxButtons.OK,
                                                         System.Windows.Forms.MessageBoxIcon.Error);
                return 1;
            }
            finally { if (log != null) log.Dispose(); }
        }
    }
}
