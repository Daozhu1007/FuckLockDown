using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace ProcessPolicyRewrite
{
    /// <summary>
    /// Locates an installed original without executing it or changing registration.
    /// A matching filename is not enough: selection is bound to the embedded plan hash.
    /// Preflight must still verify the selected file and all expected code bytes.
    /// </summary>
    internal static class TargetDiscovery
    {
        internal static string Resolve(string explicitPath, string targetName, string expectedSha256)
        {
            return ResolveFromCandidates(explicitPath, targetName, expectedSha256,
                                         String.IsNullOrWhiteSpace(explicitPath) ? InstalledCandidates(targetName) : null);
        }

        // Separate the deterministic selection policy from host registry enumeration.
        // Tests can exercise multiple installed versions without changing the machine.
        internal static string ResolveFromCandidates(string explicitPath, string targetName,
                                                      string expectedSha256, IEnumerable<string> candidates)
        {
            if (String.IsNullOrWhiteSpace(targetName) || Path.GetFileName(targetName) != targetName)
                throw new InvalidDataException("Invalid target filename in the patch plan");
            if (String.IsNullOrWhiteSpace(expectedSha256))
                throw new InvalidDataException("The patch plan does not specify a supported SHA-256");

            bool explicitSelection = !String.IsNullOrWhiteSpace(explicitPath);
            List<string> paths = new List<string>();
            HashSet<string> unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (explicitSelection)
            {
                string path = Normalize(explicitPath);
                if (!String.Equals(Path.GetFileName(path), targetName, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Unexpected target filename: " + path +
                                                   "\nExpected " + targetName + ".");
                paths.Add(path);
            }
            else if (candidates != null)
            {
                foreach (string candidate in candidates)
                {
                    string path;
                    try { path = Normalize(candidate); }
                    catch (ArgumentException) { continue; }
                    catch (NotSupportedException) { continue; }
                    catch (PathTooLongException) { continue; }
                    catch (SecurityException) { continue; }
                    if (String.Equals(Path.GetFileName(path), targetName, StringComparison.OrdinalIgnoreCase)
                        && unique.Add(path)) paths.Add(path);
                }
            }

            List<string> found = new List<string>();
            foreach (string path in paths)
            {
                if (!File.Exists(path)) continue;
                string digest;
                try
                {
                    using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                              FileShare.ReadWrite | FileShare.Delete))
                    using (SHA256 sha = SHA256.Create())
                        digest = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                }
                catch (IOException error)
                {
                    found.Add(path + "\n  Unable to read this installation: " + error.Message);
                    continue;
                }
                catch (UnauthorizedAccessException error)
                {
                    found.Add(path + "\n  Unable to read this installation: " + error.Message);
                    continue;
                }
                if (String.Equals(digest, expectedSha256, StringComparison.OrdinalIgnoreCase)) return path;
                found.Add(Describe(path) + "\n  SHA-256: " + digest);
            }

            if (found.Count > 0)
            {
                StringBuilder message = new StringBuilder();
                message.Append("找到原版程序，但与此启动器支持的版本不匹配（SHA-256 不匹配）。\n");
                message.Append("Found an original browser, but its SHA-256 does not match the supported build.\n\n");
                message.Append("支持的 SHA-256: ").Append(expectedSha256).Append("\n\n");
                for (int i = 0; i < found.Count && i < 8; ++i)
                    message.Append(found[i]).Append("\n\n");
                message.Append("请安装随本启动器说明指定的原版版本，或使用 --exe 指定完全匹配的原版文件。\n");
                message.Append("仅更改路径或使用管理员权限不能使旧版本兼容；未启动或修改上述程序。");
                throw new InvalidDataException(message.ToString());
            }

            StringBuilder missing = new StringBuilder();
            missing.Append(explicitSelection ? "指定的原版文件不存在。" : "未找到已安装的原版程序。");
            missing.Append("\nNo original ").Append(targetName).Append(" was found.\n");
            foreach (string path in paths)
                missing.Append("\n").Append(path);
            missing.Append("\n\n请先安装本启动器支持的原版版本，或使用 --exe 指定原版的完整路径。");
            throw new FileNotFoundException(missing.ToString(), explicitSelection ? paths[0] : null);
        }

        private static string Normalize(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("Empty target path");
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')));
        }

        private static string Describe(string path)
        {
            string version = "unknown";
            try
            {
                string observed = FileVersionInfo.GetVersionInfo(path).FileVersion;
                if (!String.IsNullOrEmpty(observed)) version = observed;
            }
            catch (Exception error)
            {
                if (!(error is IOException) && !(error is UnauthorizedAccessException)
                    && !(error is ArgumentException) && !(error is System.ComponentModel.Win32Exception)) throw;
            }
            return path + "\n  文件版本 / version: " + version + "; PE architecture: " + Architecture(path);
        }

        private static string Architecture(string path)
        {
            try
            {
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                          FileShare.ReadWrite | FileShare.Delete))
                using (BinaryReader reader = new BinaryReader(stream))
                {
                    if (stream.Length < 0x40 || reader.ReadUInt16() != 0x5a4d) return "not a PE image";
                    stream.Position = 0x3c;
                    int offset = reader.ReadInt32();
                    if (offset < 0 || offset > stream.Length - 6) return "invalid PE header";
                    stream.Position = offset;
                    if (reader.ReadUInt32() != 0x00004550) return "invalid PE signature";
                    ushort machine = reader.ReadUInt16();
                    if (machine == 0x8664) return "AMD64 / x64 (64-bit)";
                    if (machine == 0x014c) return "x86 (32-bit)";
                    if (machine == 0xaa64) return "ARM64 (64-bit)";
                    return "machine 0x" + machine.ToString("x4");
                }
            }
            catch (IOException) { return "unreadable"; }
            catch (UnauthorizedAccessException) { return "unreadable"; }
        }

        private static IEnumerable<string> InstalledCandidates(string targetName)
        {
            List<string> result = new List<string>();
            foreach (string directory in new string[] {
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                Environment.GetEnvironmentVariable("ProgramW6432") })
            {
                if (!String.IsNullOrWhiteSpace(directory))
                    result.Add(Path.Combine(directory, "Respondus", "LockDown Browser", targetName));
            }
            RegistryView[] views = Environment.Is64BitOperatingSystem
                ? new RegistryView[] { RegistryView.Registry64, RegistryView.Registry32 }
                : new RegistryView[] { RegistryView.Registry32 };
            foreach (RegistryHive hive in new RegistryHive[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
            foreach (RegistryView view in views)
            {
                try
                {
                    using (RegistryKey root = RegistryKey.OpenBaseKey(hive, view))
                    {
                        using (RegistryKey app = root.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" + targetName))
                        {
                            if (app != null) AddExecutableValue(result, app.GetValue(null) as string, targetName);
                        }
                        using (RegistryKey uninstall = root.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"))
                        {
                            if (uninstall == null) continue;
                            string[] names = uninstall.GetSubKeyNames();
                            Array.Sort(names, StringComparer.OrdinalIgnoreCase);
                            foreach (string name in names)
                            {
                                try
                                {
                                    using (RegistryKey item = uninstall.OpenSubKey(name))
                                    {
                                        if (item == null) continue;
                                        string display = item.GetValue("DisplayName") as string;
                                        if (display == null || (display.IndexOf("LockDown", StringComparison.OrdinalIgnoreCase) < 0
                                            && display.IndexOf("Respondus", StringComparison.OrdinalIgnoreCase) < 0)) continue;
                                        string location = item.GetValue("InstallLocation") as string;
                                        if (!String.IsNullOrWhiteSpace(location))
                                            result.Add(Path.Combine(location.Trim().Trim('"'), targetName));
                                        AddExecutableValue(result, item.GetValue("DisplayIcon") as string, targetName);
                                    }
                                }
                                catch (SecurityException) { }
                                catch (UnauthorizedAccessException) { }
                                catch (IOException) { }
                                catch (ArgumentException) { }
                            }
                        }
                    }
                }
                catch (SecurityException) { }
                catch (UnauthorizedAccessException) { }
                catch (IOException) { }
            }
            return result;
        }

        private static void AddExecutableValue(List<string> paths, string value, string targetName)
        {
            if (String.IsNullOrWhiteSpace(value)) return;
            value = Environment.ExpandEnvironmentVariables(value.Trim());
            string path;
            if (value.StartsWith("\"", StringComparison.Ordinal))
            {
                int closing = value.IndexOf('"', 1);
                if (closing < 0) return;
                path = value.Substring(1, closing - 1);
            }
            else
            {
                int end = value.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
                if (end < 0) return;
                path = value.Substring(0, end + 4);
            }
            try
            {
                if (String.Equals(Path.GetFileName(path), targetName, StringComparison.OrdinalIgnoreCase)) paths.Add(path);
            }
            catch (ArgumentException) { }
        }
    }
}
