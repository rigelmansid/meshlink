using System;
using System.Collections.Generic;
using System.Linq;

namespace Meshlink.Pairing
{
    /// <summary>
    /// A Mac paired through the plug-in, as its settings keep it, so that
    /// MeshlinkUnpair offers exactly the keys pairing installed (D-25). One
    /// line per Mac: "1|account|type base64|yyyy-MM-dd|name"; the name comes
    /// last because it may contain "|".
    /// </summary>
    public sealed class PairedMac
    {
        public string Name { get; set; }
        public string Account { get; set; }

        /// <summary>The Mac's public key, "type base64".</summary>
        public string Key { get; set; }

        /// <summary>The day it paired, yyyy-MM-dd.</summary>
        public string Date { get; set; }

        public string Label
        {
            get { return string.Format("{0}  ({1}, paired {2})", Name, Account, Date); }
        }

        public string Format()
        {
            return string.Join("|", "1", Account, Key, Date, Check.Clean(Name, 64));
        }

        /// <summary>The Mac on line, or null if the line is not one.</summary>
        public static PairedMac Parse(string line)
        {
            var f = (line ?? "").Split(new[] { '|' }, 5);
            if (f.Length != 5 || f[0] != "1" || !Check.IsAccount(f[1]) || !Check.IsPublicKey(f[2])) return null;
            return new PairedMac { Account = f[1], Key = f[2], Date = Check.Clean(f[3], 10), Name = Check.Clean(f[4], 64) };
        }

        public static List<PairedMac> ReadAll(IEnumerable<string> lines)
        {
            return (lines ?? Enumerable.Empty<string>()).Select(Parse).Where(m => m != null).ToList();
        }

        /// <summary>lines with mac recorded, replacing an older record of the same key and account.</summary>
        public static string[] Add(IEnumerable<string> lines, PairedMac mac)
        {
            return Without(lines, mac).Concat(new[] { mac.Format() }).ToArray();
        }

        public static string[] Remove(IEnumerable<string> lines, PairedMac mac)
        {
            return Without(lines, mac).ToArray();
        }

        static IEnumerable<string> Without(IEnumerable<string> lines, PairedMac mac)
        {
            foreach (var line in lines ?? Enumerable.Empty<string>())
            {
                var m = Parse(line);
                if (m != null && m.Account == mac.Account && m.Key == mac.Key) continue;
                yield return line;
            }
        }
    }
}
