using System;
using System.Text;
using ProcessPolicyRewrite;

internal static class DiscoveryHarness
{
    private static int Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            if (arguments.Length < 3) throw new ArgumentException("Expected target name, hash, explicit path or '-'");
            string[] candidates = new string[arguments.Length - 3];
            Array.Copy(arguments, 3, candidates, 0, candidates.Length);
            Console.WriteLine(TargetDiscovery.ResolveFromCandidates(
                arguments[2] == "-" ? null : arguments[2], arguments[0], arguments[1], candidates));
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine(error.GetType().Name + ": " + error.Message);
            return 3;
        }
    }
}
