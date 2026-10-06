using System;
using System.Text;
using System.Text.RegularExpressions;

namespace Meshlink.Pairing
{
    /// <summary>
    /// Formats that values read from the network must have before they are
    /// used. The Mac checks the same ones (scripts/pair.sh).
    /// </summary>
    public static class Check
    {
        // The key types prepare-windows.ps1 accepts.
        static readonly Regex PublicKeyRe = new Regex(
            @"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*$");
        static readonly Regex HostKeyRe = new Regex(@"^ssh-ed25519 [A-Za-z0-9+/]+=*$");
        static readonly Regex NonceRe = new Regex("^[0-9a-f]{32}$");
        static readonly Regex CommitRe = new Regex("^[0-9a-f]{64}$");
        // It ends up in the Mac's ~/.ssh/config, which takes only plain names.
        static readonly Regex AccountRe = new Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");

        public static bool IsPublicKey(string s) { return s != null && PublicKeyRe.IsMatch(s) && BlobMatches(s); }
        public static bool IsHostKey(string s) { return s != null && HostKeyRe.IsMatch(s) && BlobMatches(s); }
        public static bool IsNonce(string s) { return s != null && NonceRe.IsMatch(s); }
        public static bool IsCommit(string s) { return s != null && CommitRe.IsMatch(s); }
        public static bool IsAccount(string s) { return s != null && AccountRe.IsMatch(s); }

        /// <summary>
        /// "type base64": the base64 must decode, and the key blob starts with
        /// the same type (SSH wire format: a 32-bit length, then the name).
        /// </summary>
        static bool BlobMatches(string key)
        {
            int sp = key.IndexOf(' ');
            var type = key.Substring(0, sp);
            byte[] blob;
            try { blob = Convert.FromBase64String(key.Substring(sp + 1)); }
            catch (FormatException) { return false; }
            if (blob.Length < 4) return false;
            long len = ((long)blob[0] << 24) | ((long)blob[1] << 16) | ((long)blob[2] << 8) | blob[3];
            return len == type.Length && blob.Length >= 4 + len && Encoding.ASCII.GetString(blob, 4, (int)len) == type;
        }

        /// <summary>Text for the screen: control characters removed, at most max characters.</summary>
        public static string Clean(string s, int max)
        {
            var b = new StringBuilder();
            foreach (var c in s ?? "")
            {
                if (char.IsControl(c)) continue;
                if (b.Length >= max) break;
                b.Append(c);
            }
            return b.ToString().Trim();
        }

        /// <summary>Text for a message line: printable ASCII only.</summary>
        public static string Ascii(string s, int max)
        {
            var b = new StringBuilder();
            foreach (var c in s ?? "")
            {
                if (b.Length >= max) break;
                if (c >= ' ' && c <= '~') b.Append(c);
                else if (c == '\t') b.Append(' ');
                else if (c > '~') b.Append('?');
            }
            return b.ToString().Trim();
        }
    }
}
