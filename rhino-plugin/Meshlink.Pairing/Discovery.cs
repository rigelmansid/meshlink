using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Meshlink.Pairing
{
    /// <summary>A Mac announcing that it offers to pair (meshlink pair).</summary>
    public sealed class MacOffer
    {
        /// <summary>The DNS-SD instance name, as Windows reports it.</summary>
        public string Instance { get; set; }

        /// <summary>The instance label, for the screen.</summary>
        public string Name { get; set; }

        /// <summary>TXT v: the protocol version.</summary>
        public string Version { get; set; }

        /// <summary>TXT id: new for every run of meshlink pair.</summary>
        public string Id { get; set; }

        public IPEndPoint EndPoint { get; set; }
    }

    /// <summary>
    /// Finds Macs offering to pair with the DNS-SD functions of Windows 10 1809
    /// and later (dnsapi.dll). Windows itself sends and answers the multicast,
    /// so Rhino binds no port and no firewall prompt appears (pairing spike,
    /// P1 and P2). Windows only; elsewhere the calls throw DllNotFoundException.
    /// </summary>
    public static class Discovery
    {
        public const string Service = "_meshlink-pair._tcp.local";

        const uint QueryRequestVersion1 = 1;
        const int RequestPending = 9506;
        const uint ErrorCancelled = 1223;
        const ushort TypePtr = 12;

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate void BrowseCallback(uint status, IntPtr context, IntPtr record);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate void ResolveCallback(uint status, IntPtr context, IntPtr instance);

        [StructLayout(LayoutKind.Sequential)]
        struct Request
        {
            public uint Version;
            public uint InterfaceIndex;
            public IntPtr QueryName;
            public IntPtr Callback;
            public IntPtr Context;
        }

        [DllImport("dnsapi.dll")] static extern int DnsServiceBrowse(IntPtr request, IntPtr cancel);
        [DllImport("dnsapi.dll")] static extern int DnsServiceBrowseCancel(IntPtr cancel);
        [DllImport("dnsapi.dll")] static extern int DnsServiceResolve(IntPtr request, IntPtr cancel);
        [DllImport("dnsapi.dll")] static extern int DnsServiceResolveCancel(IntPtr cancel);
        [DllImport("dnsapi.dll")] static extern void DnsServiceFreeInstance(IntPtr instance);
        [DllImport("dnsapi.dll")] static extern void DnsRecordListFree(IntPtr list, int freeType);

        /// <summary>
        /// The unmanaged memory and the callback of one request. Windows may
        /// call back until it has reported the request finished, so they are
        /// released only then; a late callback must not find freed memory.
        /// </summary>
        sealed class Pending
        {
            public IntPtr Name, Request, Cancel;
            public Delegate Callback;
            public readonly TaskCompletionSource<bool> Finished =
                new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        static readonly HashSet<Pending> alive = new HashSet<Pending>();

        static Pending Prepare(string queryName, Delegate callback)
        {
            var p = new Pending { Callback = callback };
            p.Name = Marshal.StringToHGlobalUni(queryName);
            p.Request = Marshal.AllocHGlobal(Marshal.SizeOf<Request>());
            p.Cancel = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(p.Cancel, IntPtr.Zero);
            Marshal.StructureToPtr(new Request
            {
                Version = QueryRequestVersion1,
                QueryName = p.Name,
                Callback = Marshal.GetFunctionPointerForDelegate(callback),
            }, p.Request, false);
            lock (alive) alive.Add(p);
            return p;
        }

        static void Free(Pending p)
        {
            Marshal.FreeHGlobal(p.Name);
            Marshal.FreeHGlobal(p.Request);
            Marshal.FreeHGlobal(p.Cancel);
            lock (alive) alive.Remove(p);
        }

        /// <summary>Frees p once Windows has finished with it; if it never says so, keeps it.</summary>
        static async Task ReleaseAsync(Pending p)
        {
            var done = await Task.WhenAny(p.Finished.Task, Task.Delay(TimeSpan.FromSeconds(10))).ConfigureAwait(false);
            if (done == p.Finished.Task) Free(p);
        }

        /// <summary>The instance names announced during window.</summary>
        public static async Task<IReadOnlyList<string>> BrowseAsync(TimeSpan window, CancellationToken ct)
        {
            var found = new List<string>();
            Pending p = null;
            BrowseCallback cb = (status, context, record) =>
            {
                try
                {
                    // DNS_RECORDW, 64-bit (Rhino 8 is 64-bit only): 0 pNext, 8 pName,
                    // 16 wType, 18 wDataLength, 20 flags, 24 TTL, 28 reserved, 32 data
                    // (for PTR: pNameHost).
                    for (var r = record; r != IntPtr.Zero; r = Marshal.ReadIntPtr(r, 0))
                    {
                        if ((ushort)Marshal.ReadInt16(r, 16) != TypePtr) continue;
                        var ttl = (uint)Marshal.ReadInt32(r, 24);
                        var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(r, 32));
                        if (string.IsNullOrEmpty(name)) continue;
                        lock (found)
                        {
                            if (ttl == 0) found.Remove(name); // a goodbye: the Mac stopped announcing
                            else if (!found.Contains(name)) found.Add(name);
                        }
                    }
                }
                finally
                {
                    if (record != IntPtr.Zero) DnsRecordListFree(record, 1);
                    if (status != 0) p.Finished.TrySetResult(true); // cancelled or failed: no more callbacks
                }
            };
            p = Prepare(Service, cb);
            int rc = DnsServiceBrowse(p.Request, p.Cancel);
            if (rc != RequestPending)
            {
                Free(p);
                throw new PairingException("Windows could not start looking for Macs (DnsServiceBrowse " + rc + ")");
            }
            try
            {
                await Task.Delay(window, ct).ConfigureAwait(false);
            }
            finally
            {
                DnsServiceBrowseCancel(p.Cancel);
                _ = ReleaseAsync(p);
            }
            lock (found) return found.ToList();
        }

        /// <summary>The address, port and TXT of one instance, or null.</summary>
        public static async Task<MacOffer> ResolveAsync(string instance, TimeSpan timeout, CancellationToken ct)
        {
            MacOffer offer = null;
            Pending p = null;
            ResolveCallback cb = (status, context, inst) =>
            {
                try
                {
                    if (status == 0 && inst != IntPtr.Zero) offer = ReadInstance(instance, inst);
                }
                catch (Exception)
                {
                    // A record that cannot be read is the same as no answer.
                }
                finally
                {
                    if (inst != IntPtr.Zero) DnsServiceFreeInstance(inst);
                    p.Finished.TrySetResult(true);
                }
            };
            p = Prepare(instance, cb);
            int rc = DnsServiceResolve(p.Request, p.Cancel);
            if (rc != RequestPending)
            {
                Free(p);
                return null;
            }
            var delay = Task.Delay(timeout, ct);
            if (await Task.WhenAny(p.Finished.Task, delay).ConfigureAwait(false) == p.Finished.Task)
            {
                Free(p);
                return offer;
            }
            DnsServiceResolveCancel(p.Cancel);
            _ = ReleaseAsync(p);
            ct.ThrowIfCancellationRequested();
            return null;
        }

        /// <summary>Browses for window, then resolves what it found; only protocol version 1.</summary>
        public static async Task<IReadOnlyList<MacOffer>> FindAsync(TimeSpan window, CancellationToken ct)
        {
            var names = await BrowseAsync(window, ct).ConfigureAwait(false);
            var offers = await Task.WhenAll(names.Select(n => ResolveAsync(n, TimeSpan.FromSeconds(3), ct)))
                .ConfigureAwait(false);
            return offers.Where(o => o != null && o.Version == "1").ToList();
        }

        static MacOffer ReadInstance(string instance, IntPtr inst)
        {
            // DNS_SERVICE_INSTANCE, 64-bit: 0 name, 8 host, 16 ip4*, 24 ip6*, 32 port,
            // 34 priority, 36 weight, 40 property count, 48 keys, 56 values, 64 interface.
            var ip4 = Marshal.ReadIntPtr(inst, 16);
            if (ip4 == IntPtr.Zero) return null;
            var address = new IPAddress(BitConverter.GetBytes(Marshal.ReadInt32(ip4)));
            var port = (ushort)Marshal.ReadInt16(inst, 32);
            var count = Math.Min(Marshal.ReadInt32(inst, 40), 32);
            var keys = Marshal.ReadIntPtr(inst, 48);
            var values = Marshal.ReadIntPtr(inst, 56);
            var txt = new Dictionary<string, string>();
            for (int i = 0; i < count && keys != IntPtr.Zero && values != IntPtr.Zero; i++)
            {
                var k = Marshal.PtrToStringUni(Marshal.ReadIntPtr(keys, i * IntPtr.Size));
                var v = Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
                if (k != null) txt[k] = v ?? "";
            }
            string version, id;
            txt.TryGetValue("v", out version);
            txt.TryGetValue("id", out id);
            return new MacOffer
            {
                Instance = instance,
                Name = DisplayName(instance),
                Version = version,
                Id = Check.Clean(id, 32),
                EndPoint = new IPEndPoint(address, port),
            };
        }

        /// <summary>
        /// The instance label for the screen: "Ann\226\128\153s\032Mac._meshlink-pair._tcp.local"
        /// becomes "Ann\u2019s Mac". \DDD is one byte of the UTF-8 name, \c the character c.
        /// </summary>
        public static string DisplayName(string instance)
        {
            var label = instance ?? "";
            var cut = label.IndexOf("._meshlink-pair._tcp", StringComparison.OrdinalIgnoreCase);
            if (cut >= 0) label = label.Substring(0, cut);
            var bytes = new List<byte>();
            for (int i = 0; i < label.Length; i++)
            {
                int value;
                if (label[i] == '\\' && IsDigits(label, i + 1, 3) &&
                    (value = int.Parse(label.Substring(i + 1, 3))) <= 255)
                {
                    bytes.Add((byte)value);
                    i += 3;
                    continue;
                }
                if (label[i] == '\\' && i + 1 < label.Length) i++;
                int width = char.IsHighSurrogate(label[i]) && i + 1 < label.Length ? 2 : 1;
                bytes.AddRange(Encoding.UTF8.GetBytes(label.Substring(i, width)));
                i += width - 1;
            }
            return Check.Clean(Encoding.UTF8.GetString(bytes.ToArray()), 64);
        }

        static bool IsDigits(string s, int start, int count)
        {
            if (start + count > s.Length) return false;
            for (int i = start; i < start + count; i++)
                if (s[i] < '0' || s[i] > '9') return false;
            return true;
        }
    }

    /// <summary>
    /// Watches for Macs offering to pair while Rhino runs: browses for a few
    /// seconds, pauses, and again. Found fires once per run of meshlink pair
    /// (instance and TXT id); Gone when an instance is no longer announced.
    /// Browsing afresh each round does not depend on Windows reporting goodbyes.
    /// </summary>
    public sealed class DiscoveryWatcher : IDisposable
    {
        readonly HashSet<string> seen = new HashSet<string>();
        HashSet<string> current = new HashSet<string>();
        CancellationTokenSource cts;

        public event Action<MacOffer> Found;
        public event Action<string> Gone;
        public event Action<string> Problem;

        public TimeSpan Window { get; set; } = TimeSpan.FromSeconds(3);
        public TimeSpan Pause { get; set; } = TimeSpan.FromSeconds(4);

        public bool Running { get { return cts != null; } }

        public void Start()
        {
            if (cts != null) return;
            cts = new CancellationTokenSource();
            var ct = cts.Token;
            Task.Run(() => LoopAsync(ct));
        }

        public void Stop()
        {
            if (cts == null) return;
            cts.Cancel();
            cts = null;
        }

        public void Dispose()
        {
            Stop();
        }

        async Task LoopAsync(CancellationToken ct)
        {
            string lastProblem = null;
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    var names = await Discovery.BrowseAsync(Window, ct).ConfigureAwait(false);
                    var now = new HashSet<string>(names);
                    foreach (var gone in current.Where(n => !now.Contains(n)).ToList())
                        Gone?.Invoke(gone);
                    current = now;
                    // Every round, not only for new names: a Mac that pairs again
                    // under the same name has a new id.
                    var offers = await Task.WhenAll(names.Select(
                        n => Discovery.ResolveAsync(n, TimeSpan.FromSeconds(3), ct))).ConfigureAwait(false);
                    foreach (var o in offers)
                    {
                        if (o == null || o.Version != "1") continue;
                        if (seen.Add(o.Instance + "|" + o.Id)) Found?.Invoke(o);
                    }
                    lastProblem = null;
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception e)
                {
                    if (e.Message != lastProblem) Problem?.Invoke(e.Message);
                    lastProblem = e.Message;
                }
                try
                {
                    await Task.Delay(Pause, ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }
    }
}
