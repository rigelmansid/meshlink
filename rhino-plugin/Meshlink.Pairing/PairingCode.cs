using System;
using System.Security.Cryptography;
using System.Text;

namespace Meshlink.Pairing
{
    /// <summary>
    /// The values of docs/pairing.md: nonces, the commitment and the pairing
    /// code. tests/pairing-vectors.txt pins them for this code and for
    /// scripts/lib/pairing.sh alike.
    /// </summary>
    public static class PairingCode
    {
        /// <summary>16 random bytes as 32 lowercase hex digits.</summary>
        public static string NewNonce()
        {
            return Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        }

        /// <summary>
        /// An OpenSSH public key line reduced to "type base64". The comment
        /// differs between a .pub file and known_hosts, so it is never hashed.
        /// </summary>
        public static string NormalizeKey(string line)
        {
            var first = (line ?? "").Replace("\r", "").Split('\n')[0];
            var parts = first.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            return parts.Length >= 2 ? parts[0] + " " + parts[1] : "";
        }

        /// <summary>What this PC sends before it learns the Mac's nonce.</summary>
        public static string Commit(string hostKey, string nonceW)
        {
            return Hex(Sha256("meshlink-pair-v1 commit\n" + NormalizeKey(hostKey) + "\n" + nonceW + "\n"));
        }

        /// <summary>The six-digit code both screens show, as "123 456".</summary>
        public static string Code(string macKey, string hostKey, string nonceM, string nonceW)
        {
            var h = Sha256("meshlink-pair-v1 sas\n" + NormalizeKey(macKey) + "\n" + NormalizeKey(hostKey) + "\n" +
                           nonceM + "\n" + nonceW + "\n");
            uint n = ((uint)h[0] << 24) | ((uint)h[1] << 16) | ((uint)h[2] << 8) | h[3];
            var s = (n % 1000000).ToString("D6");
            return s.Substring(0, 3) + " " + s.Substring(3);
        }

        static byte[] Sha256(string text)
        {
            return SHA256.HashData(Encoding.UTF8.GetBytes(text));
        }

        static string Hex(byte[] bytes)
        {
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }
    }
}
