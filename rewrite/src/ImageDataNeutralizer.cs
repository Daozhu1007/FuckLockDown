using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace ProcessPolicyRewrite
{
    // Third kill-path coverage by neutralizing the match strings those paths
    // compare against, directly in the child's mapped .rdata. The extended
    // blacklist (0x14022b1b0), the window-class timer kill (0x140245530), the
    // WMI wireless-display sweep (0x140262690) and the remote-tool service
    // check (0x140261340) all read their needles from read-only image data,
    // not from the heap rule table the v2 rewrite empties. Corrupting one
    // equal-length byte per string leaves every comparison naturally
    // unmatched - the same semantics as an empty rule table - without
    // touching a single executable byte, so the file-based integrity checks
    // (driver path/signature binding, data-file checks) keep passing.
    //
    // Application is idempotent: a neutre whose bytes already equal the
    // replacement is skipped, so a retry after a partial failure cannot
    // turn into a false "remote bytes do not match" abort.
    internal static class ImageDataNeutralizer
    {
        internal static void Apply(IntPtr process, long imageBase, List<DataNeutre> neutres, TraceLog log)
        {
            if (neutres == null || neutres.Count == 0) return;
            List<DataNeutre> pending = new List<DataNeutre>();
            int alreadyApplied = 0;
            foreach (DataNeutre neutre in neutres)
            {
                byte[] expected = Program.Hex(neutre.expected);
                byte[] current = Program.Read(process, imageBase + Program.Rva(neutre.rva), expected.Length);
                if (Program.Equal(current, expected)) pending.Add(neutre);
                else if (Program.Equal(current, Program.Hex(neutre.replacement))) ++alreadyApplied;
                else throw new InvalidDataException("Remote bytes do not match data neutre " + neutre.id);
            }
            foreach (DataNeutre neutre in pending)
            {
                byte[] replacement = Program.Hex(neutre.replacement);
                long address = imageBase + Program.Rva(neutre.rva);
                IntPtr location = new IntPtr(address);
                UIntPtr length = new UIntPtr((uint)replacement.Length);
                uint previous;
                if (!Native.VirtualProtectEx(process, location, length, 0x04, out previous))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot make data neutre page writable");
                try
                {
                    UIntPtr written;
                    if (!Native.WriteProcessMemory(process, location, replacement, length, out written))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed for data neutre");
                    PeImage.Require(written.ToUInt64() == (ulong)replacement.Length, "Partial data neutre write");
                    PeImage.Require(Program.Equal(Program.Read(process, address, replacement.Length), replacement),
                                    "Data neutre readback mismatch");
                }
                finally
                {
                    uint ignored;
                    if (!Native.VirtualProtectEx(process, location, length, previous, out ignored))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot restore data neutre page protection");
                }
            }
            log.Event("image_data_neutralized", new {
                applied = pending.Count, alreadyApplied = alreadyApplied, total = neutres.Count,
                executableMemoryChanged = false });
        }
    }
}
