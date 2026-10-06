using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Meshlink.Pairing;

// Same options and output as the Python fake in tests/test-pair.sh:
//   --port N --hostkey FILE [--addr A]... [--user U] [--result ok|fail|declined]
//   [--message M]... [--patience SECONDS] --out FILE
// Writes NAME, SAS, CONFIRM and DONE lines to --out as it gets there.
static class Program
{
    static int Main(string[] args)
    {
        var opt = new Dictionary<string, List<string>>();
        for (int i = 0; i < args.Length; i++)
        {
            var a = args[i];
            if (!a.StartsWith("--")) { Console.Error.WriteLine("unexpected argument: " + a); return 2; }
            string key, value;
            int eq = a.IndexOf('=');
            if (eq > 0) { key = a.Substring(2, eq - 2); value = a.Substring(eq + 1); }
            else if (i + 1 < args.Length) { key = a.Substring(2); value = args[++i]; }
            else { Console.Error.WriteLine("missing value for " + a); return 2; }
            if (!opt.ContainsKey(key)) opt[key] = new List<string>();
            opt[key].Add(value);
        }
        Func<string, string, string> one = (k, d) => opt.ContainsKey(k) ? opt[k][opt[k].Count - 1] : d;
        var output = one("out", null);
        Action<string> log = line => File.AppendAllText(output, line + "\n");

        var patience = TimeSpan.FromSeconds(double.Parse(one("patience", "30"), System.Globalization.CultureInfo.InvariantCulture));
        var options = new PairingOptions { ConnectPatience = patience, MacAnswerPatience = patience };
        if (opt.ContainsKey("addr"))
        {
            // The PC only ever sends real addresses; invalid test values are
            // the Python fake's business.
            var addresses = new List<IPAddress>();
            foreach (var text in opt["addr"])
            {
                IPAddress a;
                if (IPAddress.TryParse(text, out a) && a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                    addresses.Add(a);
            }
            options.Addresses = addresses;
        }
        var result = one("result", "ok");
        var user = one("user", "agent");
        try
        {
            Run(int.Parse(one("port", "0")), File.ReadAllText(one("hostkey", null)), options,
                result == "ok" ? PairingResult.Ok : result == "declined" ? PairingResult.Declined : PairingResult.Fail,
                user, opt.ContainsKey("message") ? opt["message"] : new List<string>(), log).GetAwaiter().GetResult();
            return 0;
        }
        catch (Exception e)
        {
            log("ERROR " + e.Message.Replace("\n", " "));
            return 1;
        }
    }

    static async Task Run(int port, string hostKey, PairingOptions options, PairingResult result, string user,
                          List<string> messages, Action<string> log)
    {
        var s = await PairingSession.StartAsync(new IPEndPoint(IPAddress.Loopback, port), hostKey, options,
                                                CancellationToken.None);
        log("NAME " + s.MacName);
        log("SAS " + s.Code);
        var confirmed = await s.WaitForMacAsync(CancellationToken.None);
        log("CONFIRM " + (confirmed ? "yes" : "no"));
        if (!confirmed) return;
        await s.SendResultAsync(result, result == PairingResult.Ok ? user : null, messages, CancellationToken.None);
        log("DONE");
    }
}
