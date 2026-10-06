using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Meshlink.Pairing.Tests
{
    /// <summary>
    /// A Mac the way scripts/pair.sh behaves: for each step it starts
    /// listening only when ready (Delay), takes one connection, sends its
    /// prepared reply at once, reads the request to the end and closes.
    /// </summary>
    sealed class FakeMac
    {
        public sealed class Step
        {
            public TimeSpan Delay = TimeSpan.Zero;
            public string Reply;
        }

        public readonly int Port;
        public readonly List<string> Requests = new List<string>();

        public FakeMac()
        {
            var l = new TcpListener(IPAddress.Loopback, 0);
            l.Start();
            Port = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
        }

        public IPEndPoint EndPoint { get { return new IPEndPoint(IPAddress.Loopback, Port); } }

        public async Task ServeAsync(IEnumerable<Step> steps, CancellationToken ct)
        {
            foreach (var step in steps)
            {
                await Task.Delay(step.Delay, ct);
                var listener = new TcpListener(IPAddress.Loopback, Port);
                listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                listener.Start();
                try
                {
                    using (var client = await listener.AcceptTcpClientAsync(ct))
                    {
                        listener.Stop();
                        var stream = client.GetStream();
                        var reply = Encoding.UTF8.GetBytes(step.Reply);
                        await stream.WriteAsync(reply, 0, reply.Length, ct);
                        client.Client.Shutdown(SocketShutdown.Send);
                        var buf = new byte[65536];
                        int total = 0, n;
                        while ((n = await stream.ReadAsync(buf, total, buf.Length - total, ct)) > 0) total += n;
                        lock (Requests) Requests.Add(Encoding.UTF8.GetString(buf, 0, total));
                    }
                }
                finally
                {
                    listener.Stop();
                }
            }
        }

        public static string Reply(int step, params string[] lines)
        {
            return "MESHLINK-PAIR 1\nSTEP " + step + "\n" + (lines.Length > 0 ? string.Join("\n", lines) + "\n" : "");
        }
    }

    public class SessionTests
    {
        // Throwaway test keys, as in tests/pairing-vectors.txt.
        const string MacKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVhxr6lScYAmd/d43KR9FsrHImQD7RtN0uzVqb3WUv2 meshlink";
        const string HostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHermNu9jA9JpdA5qK07B/JfSc2BNUpb4ERv4B2O6SbK system@pc";
        const string NonceM = "00112233445566778899aabbccddeeff";

        static PairingOptions Quick()
        {
            return new PairingOptions
            {
                ConnectPatience = TimeSpan.FromSeconds(5),
                MacAnswerPatience = TimeSpan.FromSeconds(5),
                ExchangeTimeout = TimeSpan.FromSeconds(3),
                Addresses = new[] { IPAddress.Parse("192.0.2.7") },
            };
        }

        static FakeMac.Step S(int step, params string[] lines)
        {
            return new FakeMac.Step { Reply = FakeMac.Reply(step, lines) };
        }

        static FakeMac.Step S1()
        {
            return S(1, "NAME Ann’s Mac", "MACPUB " + MacKey, "NONCE " + NonceM);
        }

        [Fact]
        public async Task PairsWithAMacThatConfirms()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { S1(), S(2), S(3, "CONFIRM yes"), S(4) }, cts.Token);
                var s = await PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token);
                Assert.Equal("Ann’s Mac", s.MacName);
                Assert.Equal("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVhxr6lScYAmd/d43KR9FsrHImQD7RtN0uzVqb3WUv2", s.MacPublicKey);
                Assert.True(await s.WaitForMacAsync(cts.Token));
                await s.SendResultAsync(PairingResult.Ok, "agent", new[] { "UAC is off", "安装" }, cts.Token);
                await serving;
            }

            var r1 = PairingMessage.Parse(mac.Requests[0]);
            var r2 = PairingMessage.Parse(mac.Requests[1]);
            var r3 = PairingMessage.Parse(mac.Requests[2]);
            var r4 = PairingMessage.Parse(mac.Requests[3]);
            Assert.Equal(new[] { 1, 2, 3, 4 }, new[] { r1.Step, r2.Step, r3.Step, r4.Step });
            Assert.Equal("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHermNu9jA9JpdA5qK07B/JfSc2BNUpb4ERv4B2O6SbK", r2.Get("HOSTKEY"));
            // The commitment of step 1 fits what step 2 revealed.
            Assert.Equal(r1.Get("COMMIT"), PairingCode.Commit(r2.Get("HOSTKEY"), r2.Get("NONCE")));
            Assert.Equal(new[] { "192.0.2.7" }, r2.GetAll("ADDR"));
            Assert.Equal("ok", r4.Get("RESULT"));
            Assert.Equal("agent", r4.Get("USER"));
            Assert.Equal(new[] { "UAC is off", "??" }, r4.GetAll("MESSAGE"));
        }

        [Fact]
        public async Task CodeIsWhatTheMacComputes()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { S1(), S(2) }, cts.Token);
                var s = await PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token);
                await serving;
                var r2 = PairingMessage.Parse(mac.Requests[1]);
                Assert.Equal(PairingCode.Code(MacKey, HostKey, NonceM, r2.Get("NONCE")), s.Code);
                Assert.Matches("^[0-9]{3} [0-9]{3}$", s.Code);
            }
        }

        [Fact]
        public async Task WaitsForAMacThatListensLate()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var late = new FakeMac.Step { Delay = TimeSpan.FromSeconds(1.5), Reply = FakeMac.Reply(3, "CONFIRM no") };
                var first = new FakeMac.Step { Delay = TimeSpan.FromSeconds(1), Reply = S1().Reply };
                var serving = mac.ServeAsync(new[] { first, S(2), late }, cts.Token);
                var s = await PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token);
                Assert.False(await s.WaitForMacAsync(cts.Token));
                await serving;
            }
        }

        [Fact]
        public async Task RetriesWhenAnotherStepAnswers()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { S(2), S1(), S(2) }, cts.Token);
                var s = await PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token);
                await serving;
                Assert.Equal(3, mac.Requests.Count);
                Assert.NotNull(s.Code);
            }
        }

        [Theory]
        [InlineData("MACPUB ssh-ed25519 not base64!", "NONCE 00112233445566778899aabbccddeeff")]
        [InlineData("MACPUB ssh-ed25519 bm90IGEga2V5", "NONCE 00112233445566778899aabbccddeeff")]
        [InlineData("MACPUB " + MacKey, "NONCE short")]
        public async Task RejectsAMalformedFirstReply(string a, string b)
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { S(1, "NAME x", a, b) }, cts.Token);
                var e = await Assert.ThrowsAsync<PairingException>(
                    () => PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token));
                Assert.Contains("malformed", e.Message);
                await serving;
            }
        }

        [Fact]
        public async Task RejectsAnOversizedReply()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { new FakeMac.Step { Reply = new string('x', 70000) } }, cts.Token);
                var e = await Assert.ThrowsAsync<PairingException>(
                    () => PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token));
                Assert.Contains("too long", e.Message);
                try { await serving; } catch (Exception) { }
            }
        }

        [Fact]
        public async Task GivesUpOnAMacThatNeverListens()
        {
            var mac = new FakeMac();
            var options = Quick();
            options.ConnectPatience = TimeSpan.FromSeconds(1);
            var e = await Assert.ThrowsAsync<PairingException>(
                () => PairingSession.StartAsync(mac.EndPoint, HostKey, options, CancellationToken.None));
            Assert.Contains("did not answer step 1", e.Message);
        }

        [Fact]
        public async Task RefusesAHostKeyThatIsNotEd25519()
        {
            var e = await Assert.ThrowsAsync<PairingException>(
                () => PairingSession.StartAsync(new FakeMac().EndPoint, "ssh-rsa AAAAB3NzaC1yc2E= x", Quick(), CancellationToken.None));
            Assert.Contains("ED25519", e.Message);
        }

        [Fact]
        public async Task OnlySendsAccountsTheMacAccepts()
        {
            var mac = new FakeMac();
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
            {
                var serving = mac.ServeAsync(new[] { S1(), S(2) }, cts.Token);
                var s = await PairingSession.StartAsync(mac.EndPoint, HostKey, Quick(), cts.Token);
                await serving;
                await Assert.ThrowsAsync<ArgumentException>(
                    () => s.SendResultAsync(PairingResult.Ok, "agent ProxyCommand evil", null, cts.Token));
            }
        }
    }
}
