using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace MeshlinkProbe
{
    // Win32 DNS-SD (dnsapi.dll, Windows 10 1809+). The OS DNS client does the
    // multicast, so Rhino.exe never binds UDP 5353 itself.
    internal static class Dns
    {
        const uint DNS_QUERY_REQUEST_VERSION1 = 1;
        const int DNS_REQUEST_PENDING = 9506;
        const ushort DNS_TYPE_PTR = 12;

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

        public class Instance
        {
            public string Name, Host;
            public ushort Port;
            public List<string> IPv4 = new List<string>();
            public Dictionary<string, string> Txt = new Dictionary<string, string>();
        }

        // Callbacks must stay reachable while a request is pending.
        static readonly List<object> keepAlive = new List<object>();

        public static List<string> Browse(string service, int milliseconds, Action<string> log)
        {
            var found = new ConcurrentDictionary<string, bool>();
            BrowseCallback cb = (status, ctx, rec) =>
            {
                try
                {
                    log("browse callback status=" + status);
                    for (IntPtr p = rec; p != IntPtr.Zero; p = Marshal.ReadIntPtr(p, 0))
                    {
                        // DNS_RECORDW, 64-bit: 0 pNext, 8 pName, 16 wType, 18 wDataLength,
                        // 20 flags, 24 ttl, 28 reserved, 32 data (PTR: pNameHost).
                        ushort type = (ushort)Marshal.ReadInt16(p, 16);
                        if (type == DNS_TYPE_PTR)
                        {
                            string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, 32));
                            if (name != null) found[name] = true;
                        }
                    }
                }
                finally { if (rec != IntPtr.Zero) DnsRecordListFree(rec, 1); }
            };
            lock (keepAlive) keepAlive.Add(cb);
            IntPtr name = Marshal.StringToHGlobalUni(service);
            IntPtr req = Marshal.AllocHGlobal(Marshal.SizeOf<Request>());
            IntPtr cancel = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(cancel, IntPtr.Zero);
            Marshal.StructureToPtr(new Request
            {
                Version = DNS_QUERY_REQUEST_VERSION1,
                QueryName = name,
                Callback = Marshal.GetFunctionPointerForDelegate(cb),
            }, req, false);
            int rc = DnsServiceBrowse(req, cancel);
            log("DnsServiceBrowse rc=" + rc + (rc == DNS_REQUEST_PENDING ? " (pending, ok)" : " (unexpected)"));
            if (rc == DNS_REQUEST_PENDING)
            {
                Wait(milliseconds);
                log("DnsServiceBrowseCancel rc=" + DnsServiceBrowseCancel(cancel));
                Wait(500);
            }
            return new List<string>(found.Keys);
            // name/req/cancel are deliberately leaked: a late callback must not see freed memory.
        }

        public static Instance Resolve(string instanceName, int milliseconds, Action<string> log)
        {
            Instance result = null;
            var done = new System.Threading.ManualResetEventSlim();
            ResolveCallback cb = (status, ctx, inst) =>
            {
                try
                {
                    log("resolve callback status=" + status);
                    if (inst == IntPtr.Zero) return;
                    // DNS_SERVICE_INSTANCE, 64-bit layout (Rhino 8 is 64-bit only):
                    // 0 name, 8 host, 16 ip4*, 24 ip6*, 32 port, 34 priority, 36 weight,
                    // 40 property count, 48 keys, 56 values, 64 interface index.
                    var r = new Instance();
                    r.Name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(inst, 0));
                    r.Host = Marshal.PtrToStringUni(Marshal.ReadIntPtr(inst, 8));
                    IntPtr ip4 = Marshal.ReadIntPtr(inst, 16);
                    if (ip4 != IntPtr.Zero)
                        r.IPv4.Add(new System.Net.IPAddress(BitConverter.GetBytes(Marshal.ReadInt32(ip4))).ToString());
                    r.Port = (ushort)Marshal.ReadInt16(inst, 32);
                    int count = Marshal.ReadInt32(inst, 40);
                    IntPtr keys = Marshal.ReadIntPtr(inst, 48);
                    IntPtr values = Marshal.ReadIntPtr(inst, 56);
                    for (int i = 0; i < count; i++)
                    {
                        string k = Marshal.PtrToStringUni(Marshal.ReadIntPtr(keys, i * 8));
                        string v = Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * 8));
                        if (k != null) r.Txt[k] = v ?? "";
                    }
                    result = r;
                }
                finally
                {
                    if (inst != IntPtr.Zero) DnsServiceFreeInstance(inst);
                    done.Set();
                }
            };
            lock (keepAlive) keepAlive.Add(cb);
            IntPtr name = Marshal.StringToHGlobalUni(instanceName);
            IntPtr req = Marshal.AllocHGlobal(Marshal.SizeOf<Request>());
            IntPtr cancel = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(cancel, IntPtr.Zero);
            Marshal.StructureToPtr(new Request
            {
                Version = DNS_QUERY_REQUEST_VERSION1,
                QueryName = name,
                Callback = Marshal.GetFunctionPointerForDelegate(cb),
            }, req, false);
            int rc = DnsServiceResolve(req, cancel);
            log("DnsServiceResolve rc=" + rc + (rc == DNS_REQUEST_PENDING ? " (pending, ok)" : " (unexpected)"));
            if (rc == DNS_REQUEST_PENDING)
            {
                var t0 = DateTime.UtcNow;
                while (!done.IsSet && (DateTime.UtcNow - t0).TotalMilliseconds < milliseconds) Wait(100);
                if (!done.IsSet) log("DnsServiceResolveCancel rc=" + DnsServiceResolveCancel(cancel));
            }
            return result;
        }

        // Keep Rhino's UI responsive while waiting on the UI thread.
        static void Wait(int milliseconds)
        {
            var t0 = DateTime.UtcNow;
            while ((DateTime.UtcNow - t0).TotalMilliseconds < milliseconds)
            {
                Rhino.RhinoApp.Wait();
                System.Threading.Thread.Sleep(50);
            }
        }
    }
}
