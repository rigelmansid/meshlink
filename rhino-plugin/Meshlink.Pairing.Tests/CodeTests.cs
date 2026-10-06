using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

namespace Meshlink.Pairing.Tests
{
    public class CodeTests
    {
        public static IEnumerable<object[]> Vectors()
        {
            foreach (var line in File.ReadAllLines(Repo.PathOf("tests", "pairing-vectors.txt")))
            {
                if (line.Length == 0 || line.StartsWith("#")) continue;
                var f = line.Split('|');
                // A literal \r in a vector field stands for a CR byte.
                yield return new object[] { f[0], f[1].Replace("\\r", "\r"), f[2].Replace("\\r", "\r"), f[3], f[4], f[5], f[6] };
            }
        }

        [Fact]
        public void HasAllVectors()
        {
            Assert.True(Vectors().Count() >= 4);
        }

        [Theory]
        [MemberData(nameof(Vectors))]
        public void MatchesVector(string name, string macKey, string hostKey, string nonceM, string nonceW,
                                  string commit, string code)
        {
            Assert.Equal(commit, PairingCode.Commit(hostKey, nonceW));
            Assert.Equal(code, PairingCode.Code(macKey, hostKey, nonceM, nonceW));
            Assert.NotNull(name);
        }

        [Fact]
        public void NoncesAreFreshHex()
        {
            var a = PairingCode.NewNonce();
            var b = PairingCode.NewNonce();
            Assert.Matches("^[0-9a-f]{32}$", a);
            Assert.NotEqual(a, b);
        }

        [Theory]
        [InlineData("ssh-ed25519 AAAA comment", "ssh-ed25519 AAAA")]
        [InlineData("ssh-ed25519\tAAAA\r", "ssh-ed25519 AAAA")]
        [InlineData("ssh-ed25519 AAAA\nssh-rsa BBBB", "ssh-ed25519 AAAA")]
        [InlineData("ssh-ed25519", "")]
        [InlineData(null, "")]
        public void NormalizesKeys(string line, string expected)
        {
            Assert.Equal(expected, PairingCode.NormalizeKey(line));
        }
    }
}
