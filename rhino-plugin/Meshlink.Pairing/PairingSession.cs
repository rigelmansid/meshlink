using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Meshlink.Pairing
{
    public enum PairingResult { Ok, Fail, Declined }

    public sealed class PairingException : Exception
    {
        public PairingException(string message) : base(message) { }
    }

    public sealed class PairingOptions
    {
        /// <summary>Steps 1, 2 and 4: how long a refused connection is retried.</summary>
        public TimeSpan ConnectPatience { get; set; } = TimeSpan.FromSeconds(15);

        /// <summary>Step 3: the Mac listens only once its user has answered.</summary>
        public TimeSpan MacAnswerPatience { get; set; } = TimeSpan.FromMinutes(15);

        /// <summary>One connection, from connecting to the end of the reply.</summary>
        public TimeSpan ExchangeTimeout { get; set; } = TimeSpan.FromSeconds(10);

        /// <summary>
        /// The addresses sent as ADDR. Null: the address this PC used to reach
        /// the Mac, then its other IPv4 addresses.
        /// </summary>
        public IReadOnlyList<IPAddress> Addresses { get; set; }
    }

    /// <summary>
    /// The PC's side of docs/pairing.md. Each step is one TCP connection: send
    /// the request, close the sending side, read the reply. The Mac listens
    /// for a step only once it is ready for it, so refused connections are
    /// retried.
    /// </summary>
    public sealed class PairingSession
    {
        const int MaxReply = 64 * 1024;

        readonly IPEndPoint mac;
        readonly PairingOptions options;
        IPAddress localAddress;

        PairingSession(IPEndPoint mac, PairingOptions options)
        {
            this.mac = mac;
            this.options = options ?? new PairingOptions();
        }

        public string MacName { get; private set; }

        /// <summary>The Mac's public key, "type base64".</summary>
        public string MacPublicKey { get; private set; }

        /// <summary>The pairing code, "123 456".</summary>
        public string Code { get; private set; }

        /// <summary>
        /// Steps 1 and 2: commit to this PC's host key, learn the Mac's key
        /// and nonce, reveal. Afterwards Code is what both screens show.
        /// </summary>
        public static async Task<PairingSession> StartAsync(IPEndPoint mac, string hostKeyLine,
                                                            PairingOptions options, CancellationToken ct)
        {
            var hostKey = PairingCode.NormalizeKey(hostKeyLine);
            if (!Check.IsHostKey(hostKey))
                throw new PairingException("this PC's SSH host key is not an ED25519 key");

            var s = new PairingSession(mac, options);
            var nonceW = PairingCode.NewNonce();

            var r1 = await s.ExchangeAsync(1, new[] { F("COMMIT", PairingCode.Commit(hostKey, nonceW)) },
                                           s.options.ConnectPatience, ct).ConfigureAwait(false);
            var macKey = PairingCode.NormalizeKey(r1.Get("MACPUB"));
            var nonceM = r1.Get("NONCE");
            if (!Check.IsPublicKey(macKey) || !Check.IsNonce(nonceM))
                throw new PairingException("the Mac sent a malformed first reply");
            s.MacPublicKey = macKey;
            s.MacName = Check.Clean(r1.Get("NAME"), 64);

            var fields = new List<KeyValuePair<string, string>> { F("HOSTKEY", hostKey), F("NONCE", nonceW) };
            foreach (var a in s.options.Addresses ?? s.DefaultAddresses())
                fields.Add(F("ADDR", a.ToString()));
            await s.ExchangeAsync(2, fields, s.options.ConnectPatience, ct).ConfigureAwait(false);

            s.Code = PairingCode.Code(macKey, hostKey, nonceM, nonceW);
            return s;
        }

        /// <summary>Step 3: true if the Mac's user confirmed the code.</summary>
        public async Task<bool> WaitForMacAsync(CancellationToken ct)
        {
            var r3 = await ExchangeAsync(3, new KeyValuePair<string, string>[0], options.MacAnswerPatience, ct)
                .ConfigureAwait(false);
            return r3.Get("CONFIRM") == "yes";
        }

        /// <summary>Step 4, only after the Mac confirmed: what happened on this PC.</summary>
        public Task SendResultAsync(PairingResult result, string user, IEnumerable<string> messages,
                                    CancellationToken ct)
        {
            var fields = new List<KeyValuePair<string, string>>
            {
                F("RESULT", result == PairingResult.Ok ? "ok" : result == PairingResult.Declined ? "declined" : "fail"),
            };
            if (result == PairingResult.Ok)
            {
                if (!Check.IsAccount(user)) throw new ArgumentException("not an account name the Mac accepts: " + user);
                fields.Add(F("USER", user));
            }
            foreach (var m in (messages ?? Enumerable.Empty<string>()).Take(20))
            {
                var line = Check.Ascii(m, 300);
                if (line.Length > 0) fields.Add(F("MESSAGE", line));
            }
            return ExchangeAsync(4, fields, options.ConnectPatience, ct);
        }

        IEnumerable<IPAddress> DefaultAddresses()
        {
            var all = new List<IPAddress>();
            if (localAddress != null) all.Add(localAddress);
            foreach (var a in OtherIPv4Addresses())
                if (!all.Contains(a)) all.Add(a);
            return all;
        }

        static IEnumerable<IPAddress> OtherIPv4Addresses()
        {
            NetworkInterface[] nics;
            try { nics = NetworkInterface.GetAllNetworkInterfaces(); }
            catch (NetworkInformationException) { yield break; }
            foreach (var nic in nics)
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                foreach (var u in nic.GetIPProperties().UnicastAddresses)
                {
                    var a = u.Address;
                    if (a.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(a)) continue;
                    var b = a.GetAddressBytes();
                    if (b[0] == 169 && b[1] == 254) continue; // no DHCP lease: never reachable
                    yield return a;
                }
            }
        }

        async Task<PairingMessage> ExchangeAsync(int step, IEnumerable<KeyValuePair<string, string>> fields,
                                                 TimeSpan patience, CancellationToken ct)
        {
            var payload = Encoding.UTF8.GetBytes(PairingMessage.Format(step, fields));
            var deadline = DateTime.UtcNow + patience;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                string reply = null;
                try
                {
                    reply = await TalkAsync(payload, ct).ConfigureAwait(false);
                }
                catch (SocketException e) when (e.SocketErrorCode == SocketError.ConnectionRefused ||
                                                e.SocketErrorCode == SocketError.ConnectionReset)
                {
                    // Not listening yet, or between two steps.
                }
                if (reply != null)
                {
                    var msg = PairingMessage.Parse(reply);
                    // Another step's reply means the Mac was not at this step yet.
                    if (msg != null && msg.Step == step) return msg;
                }
                if (DateTime.UtcNow >= deadline)
                    throw new PairingException(reply == null
                        ? string.Format("the Mac did not answer step {0} of the pairing", step)
                        : string.Format("the Mac sent no proper reply to step {0} of the pairing", step));
                await Task.Delay(200, ct).ConfigureAwait(false);
            }
        }

        async Task<string> TalkAsync(byte[] payload, CancellationToken ct)
        {
            using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            using (var client = new TcpClient(mac.AddressFamily))
            {
                cts.CancelAfter(options.ExchangeTimeout);
                bool connected = false;
                try
                {
                    await client.ConnectAsync(mac.Address, mac.Port, cts.Token).ConfigureAwait(false);
                    connected = true;
                    if (localAddress == null)
                        localAddress = ((IPEndPoint)client.Client.LocalEndPoint).Address;
                    var stream = client.GetStream();
                    await stream.WriteAsync(payload, 0, payload.Length, cts.Token).ConfigureAwait(false);
                    client.Client.Shutdown(SocketShutdown.Send);
                    var buffer = new byte[MaxReply];
                    int total = 0;
                    while (true)
                    {
                        int n = await stream.ReadAsync(buffer, total, buffer.Length - total, cts.Token)
                            .ConfigureAwait(false);
                        if (n == 0) break;
                        total += n;
                        if (total == buffer.Length) throw new PairingException("the Mac's reply is too long");
                    }
                    return Encoding.UTF8.GetString(buffer, 0, total);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new PairingException(connected
                        ? "the Mac stopped answering in the middle of a step"
                        : "could not reach the Mac at " + mac);
                }
                catch (SocketException e) when (e.SocketErrorCode != SocketError.ConnectionRefused &&
                                                e.SocketErrorCode != SocketError.ConnectionReset)
                {
                    throw new PairingException("could not reach the Mac at " + mac + ": " + e.Message);
                }
            }
        }

        static KeyValuePair<string, string> F(string key, string value)
        {
            return new KeyValuePair<string, string>(key, value);
        }
    }
}
