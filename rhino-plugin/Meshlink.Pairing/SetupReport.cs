using System.Collections.Generic;

namespace Meshlink.Pairing
{
    /// <summary>
    /// What prepare-windows.ps1 -ResultFile wrote: "RESULT ok|fail",
    /// "USER account", then "LINE text" per report line.
    /// </summary>
    public sealed class SetupReport
    {
        public bool Ok { get; private set; }
        public string User { get; private set; }
        public List<string> Lines { get; } = new List<string>();

        public static SetupReport Parse(IEnumerable<string> fileLines)
        {
            var r = new SetupReport();
            foreach (var line in fileLines)
            {
                if (line.StartsWith("RESULT ")) r.Ok = line.Substring(7).Trim() == "ok";
                else if (line.StartsWith("USER ")) r.User = line.Substring(5).Trim();
                else if (line.StartsWith("LINE ")) r.Lines.Add(line.Substring(5));
            }
            return r;
        }

        /// <summary>
        /// FAIL, WARN and SKIP lines with the hints under them: what the Mac
        /// is told. A SKIP matters too: rhinomcp not installed for another
        /// account is one.
        /// </summary>
        public List<string> Notable()
        {
            var notable = new List<string>();
            bool keep = false;
            foreach (var line in Lines)
            {
                if (line.StartsWith("[FAIL]") || line.StartsWith("[WARN]") || line.StartsWith("[SKIP]")) keep = true;
                else if (!line.TrimStart().StartsWith("->")) keep = false;
                if (keep) notable.Add(line.Trim());
            }
            return notable;
        }
    }
}
