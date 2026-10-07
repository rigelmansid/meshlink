using Xunit;

namespace Meshlink.Pairing.Tests
{
    public class PairedMacTests
    {
        const string Key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVhxr6lScYAmd/d43KR9FsrHImQD7RtN0uzVqb3WUv2";
        const string Other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHermNu9jA9JpdA5qK07B/JfSc2BNUpb4ERv4B2O6SbK";

        static PairedMac Mac(string name, string account, string key)
        {
            return new PairedMac { Name = name, Account = account, Key = key, Date = "2026-10-07" };
        }

        [Fact]
        public void RoundTripsANameWithABar()
        {
            var line = Mac("Ann's Mac | studio", "rhino-agent", Key).Format();
            Assert.Equal("1|rhino-agent|" + Key + "|2026-10-07|Ann's Mac | studio", line);
            var m = PairedMac.Parse(line);
            Assert.Equal("Ann's Mac | studio", m.Name);
            Assert.Equal("rhino-agent", m.Account);
            Assert.Equal(Key, m.Key);
            Assert.Equal("Ann's Mac | studio  (rhino-agent, paired 2026-10-07)", m.Label);
        }

        [Theory]
        [InlineData("")]
        [InlineData("2|rhino-agent|ssh-ed25519 AAAA|2026-10-07|x")]
        [InlineData("1|agent ProxyCommand x|" + Key + "|2026-10-07|x")]
        [InlineData("1|rhino-agent|ssh-ed25519 bm90IGEga2V5|2026-10-07|x")]
        [InlineData("1|rhino-agent|" + Key + "|2026-10-07")]
        public void SkipsWhatIsNotARecord(string line)
        {
            Assert.Null(PairedMac.Parse(line));
            Assert.Empty(PairedMac.ReadAll(new[] { line }));
        }

        [Fact]
        public void AddReplacesTheSameKeyForTheSameAccount()
        {
            var lines = PairedMac.Add(new string[0], Mac("old name", "rhino-agent", Key));
            lines = PairedMac.Add(lines, Mac("Other Mac", "rhino-agent", Other));
            lines = PairedMac.Add(lines, Mac("new name", "rhino-agent", Key));
            lines = PairedMac.Add(lines, Mac("new name", "someone", Key));
            var all = PairedMac.ReadAll(lines);
            Assert.Equal(new[] { "Other Mac", "new name", "new name" }, all.ConvertAll(m => m.Name));
            Assert.Equal(new[] { "rhino-agent", "rhino-agent", "someone" }, all.ConvertAll(m => m.Account));
        }

        [Fact]
        public void RemoveTakesOnlyThatKeyAndAccount()
        {
            var lines = new[]
            {
                Mac("a", "rhino-agent", Key).Format(),
                "something else",
                Mac("b", "rhino-agent", Other).Format(),
                Mac("c", "someone", Key).Format(),
            };
            var left = PairedMac.Remove(lines, Mac("x", "rhino-agent", Key));
            Assert.Equal(new[] { lines[1], lines[2], lines[3] }, left);
        }
    }
}
