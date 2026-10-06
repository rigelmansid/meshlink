using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Meshlink.Pairing
{
    /// <summary>
    /// One message of docs/pairing.md: "MESHLINK-PAIR 1", "STEP n", then
    /// "KEY value" lines.
    /// </summary>
    public sealed class PairingMessage
    {
        public const string Header = "MESHLINK-PAIR 1";

        readonly List<KeyValuePair<string, string>> fields;

        PairingMessage(int step, List<KeyValuePair<string, string>> fields)
        {
            Step = step;
            this.fields = fields;
        }

        public int Step { get; }

        /// <summary>The first value of key, or null.</summary>
        public string Get(string key)
        {
            foreach (var f in fields)
                if (f.Key == key) return f.Value;
            return null;
        }

        public IReadOnlyList<string> GetAll(string key)
        {
            var all = new List<string>();
            foreach (var f in fields)
                if (f.Key == key) all.Add(f.Value);
            return all;
        }

        public static string Format(int step, IEnumerable<KeyValuePair<string, string>> fields)
        {
            var b = new StringBuilder();
            b.Append(Header).Append('\n');
            b.Append("STEP ").Append(step.ToString(CultureInfo.InvariantCulture)).Append('\n');
            foreach (var f in fields)
            {
                if (f.Key.IndexOfAny(new[] { ' ', '\r', '\n' }) >= 0 ||
                    (f.Value ?? "").IndexOfAny(new[] { '\r', '\n' }) >= 0)
                    throw new ArgumentException("a field would break the line format: " + f.Key);
                b.Append(f.Key).Append(' ').Append(f.Value ?? "").Append('\n');
            }
            return b.ToString();
        }

        /// <summary>The message in text, or null if it is not one (wrong header or no step).</summary>
        public static PairingMessage Parse(string text)
        {
            var lines = (text ?? "").Replace("\r", "").Split('\n');
            if (lines[0] != Header) return null;
            var fields = new List<KeyValuePair<string, string>>();
            for (int i = 1; i < lines.Length; i++)
            {
                if (lines[i].Length == 0) continue;
                int sp = lines[i].IndexOf(' ');
                fields.Add(sp < 0
                    ? new KeyValuePair<string, string>(lines[i], "")
                    : new KeyValuePair<string, string>(lines[i].Substring(0, sp), lines[i].Substring(sp + 1)));
            }
            foreach (var f in fields)
            {
                if (f.Key != "STEP") continue;
                int step;
                if (!int.TryParse(f.Value, NumberStyles.None, CultureInfo.InvariantCulture, out step)) return null;
                return new PairingMessage(step, fields);
            }
            return null;
        }
    }
}
