using Xunit;

namespace Meshlink.Pairing.Tests
{
    public class CheckTests
    {
        [Theory]
        [InlineData("agent", true)]
        [InlineData("rhino-agent_1.x", true)]
        [InlineData("agent ProxyCommand evil", false)]
        [InlineData("-oProxyCommand", false)]
        [InlineData("", false)]
        [InlineData("aé", false)]
        public void Accounts(string name, bool ok)
        {
            Assert.Equal(ok, Check.IsAccount(name));
        }

        [Theory]
        [InlineData("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVhxr6lScYAmd/d43KR9FsrHImQD7RtN0uzVqb3WUv2", true, true)]
        [InlineData("ssh-rsa AAAAB3NzaC1yc2E=", true, false)]
        [InlineData("ssh-ed25519 AAAA meshlink", false, false)]
        [InlineData("ssh-dss AAAA", false, false)]
        [InlineData("ssh-ed25519 bm90IGEga2V5", false, false)]
        [InlineData("ssh-ed25519 AAAAB3NzaC1yc2E=", false, false)]
        public void Keys(string key, bool publicKey, bool hostKey)
        {
            Assert.Equal(publicKey, Check.IsPublicKey(key));
            Assert.Equal(hostKey, Check.IsHostKey(key));
        }

        [Fact]
        public void CleanRemovesControlCharacters()
        {
            Assert.Equal("sshd is not[31m installed", Check.Clean("sshd is not\u001b[31m installed\r\n", 100));
            Assert.Equal("Ann’s Mac", Check.Clean("Ann’s Mac", 100));
            Assert.Equal("abc", Check.Clean("abcdef", 3));
        }

        [Fact]
        public void AsciiReplacesTheRest()
        {
            Assert.Equal("sshd ?? [31m", Check.Ascii("sshd 安装 \u001b[31m", 100));
        }

        [Theory]
        [InlineData("Ann\\226\\128\\153s\\032Mac._meshlink-pair._tcp.local", "Ann’s Mac")]
        [InlineData("plain._meshlink-pair._tcp.local", "plain")]
        [InlineData("dot\\.name._meshlink-pair._tcp.local.", "dot.name")]
        [InlineData("bad\\999._meshlink-pair._tcp.local", "bad999")]
        public void DisplayNames(string instance, string expected)
        {
            Assert.Equal(expected, Discovery.DisplayName(instance));
        }
    }
}
