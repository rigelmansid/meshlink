using System;
using System.Collections.Generic;
using Xunit;

namespace Meshlink.Pairing.Tests
{
    public class MessageTests
    {
        static KeyValuePair<string, string> F(string k, string v) { return new KeyValuePair<string, string>(k, v); }

        [Fact]
        public void RoundTrips()
        {
            var text = PairingMessage.Format(2, new[] { F("HOSTKEY", "ssh-ed25519 AAAA"), F("ADDR", "192.0.2.1"), F("ADDR", "192.0.2.2") });
            Assert.Equal("MESHLINK-PAIR 1\nSTEP 2\nHOSTKEY ssh-ed25519 AAAA\nADDR 192.0.2.1\nADDR 192.0.2.2\n", text);
            var m = PairingMessage.Parse(text);
            Assert.Equal(2, m.Step);
            Assert.Equal("ssh-ed25519 AAAA", m.Get("HOSTKEY"));
            Assert.Equal(new[] { "192.0.2.1", "192.0.2.2" }, m.GetAll("ADDR"));
            Assert.Null(m.Get("NONCE"));
        }

        [Fact]
        public void ReadsCrlfAndEmptyValues()
        {
            var m = PairingMessage.Parse("MESHLINK-PAIR 1\r\nSTEP 4\r\nRESULT ok\r\nMESSAGE\r\n");
            Assert.Equal(4, m.Step);
            Assert.Equal("ok", m.Get("RESULT"));
            Assert.Equal("", m.Get("MESSAGE"));
        }

        [Theory]
        [InlineData("GET / HTTP/1.0\r\n\r\n")]
        [InlineData("MESHLINK-PAIR 2\nSTEP 1\n")]
        [InlineData("MESHLINK-PAIR 1\nCOMMIT x\n")]
        [InlineData("MESHLINK-PAIR 1\nSTEP one\n")]
        [InlineData("")]
        [InlineData(null)]
        public void RejectsWhatIsNotAMessage(string text)
        {
            Assert.Null(PairingMessage.Parse(text));
        }

        [Fact]
        public void RefusesValuesThatWouldBreakTheFormat()
        {
            Assert.Throws<ArgumentException>(() => PairingMessage.Format(4, new[] { F("MESSAGE", "a\nUSER root") }));
        }
    }
}
