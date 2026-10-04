using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Rhino;
using Rhino.Commands;

namespace MeshlinkProbe
{
    // Checks the four assumptions D-20 rests on; see README.md in this folder.
    [Guid("424E1D5A-1141-4618-86FC-F8D5FB6026FE")]
    public class MeshlinkProbeCommand : Command
    {
        public override string EnglishName => "MeshlinkProbe";

        const string Service = "_meshlink-pair._tcp.local";

        static void Log(string s) => RhinoApp.WriteLine("[probe] " + s);

        protected override Result RunCommand(RhinoDoc doc, RunMode mode)
        {
            Log("Rhino " + RhinoApp.Version + ", " + RuntimeInformation.FrameworkDescription +
                ", " + RuntimeInformation.OSDescription + ", 64-bit=" + Environment.Is64BitProcess);

            // P1: discovery of the Mac's dns-sd -R
            var names = Dns.Browse(Service, 8000, s => RhinoApp.InvokeOnUiThread(new Action(() => Log(s))));
            Log("P1 browse found " + names.Count + ": " + string.Join(" | ", names));
            Dns.Instance inst = null;
            if (names.Count > 0)
            {
                inst = Dns.Resolve(names[0], 5000, s => RhinoApp.InvokeOnUiThread(new Action(() => Log(s))));
                if (inst == null) Log("P1 resolve FAILED");
                else Log("P1 resolve: name=" + inst.Name + " host=" + inst.Host + " ip4=" +
                         string.Join(",", inst.IPv4) + " port=" + inst.Port + " txt=" +
                         string.Join(",", inst.Txt));
            }

            // P2: outbound TCP to the Mac's nc -l
            if (inst != null && inst.IPv4.Count > 0)
            {
                try
                {
                    using (var c = new TcpClient())
                    {
                        c.Connect(inst.IPv4[0], inst.Port);
                        var st = c.GetStream();
                        var hello = Encoding.ASCII.GetBytes("PROBE from " + Environment.MachineName + "\n");
                        st.Write(hello, 0, hello.Length);
                        c.Client.Shutdown(SocketShutdown.Send);
                        var reply = new StreamReader(st, Encoding.ASCII).ReadToEnd();
                        Log("P2 tcp ok, Mac replied: " + reply.Trim());
                    }
                }
                catch (Exception e) { Log("P2 tcp FAILED: " + e.Message); }
            }
            else Log("P2 skipped (nothing resolved)");

            // P3: host key readable without elevation
            string hostKey = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                                          "ssh", "ssh_host_ed25519_key.pub");
            try { Log("P3 host key: " + File.ReadAllText(hostKey).Trim()); }
            catch (Exception e) { Log("P3 host key FAILED: " + e.Message); }

            // P4: UAC elevation, and whether the elevated child can hand back a result file
            string outFile = Path.Combine(Path.GetTempPath(), "meshlink-probe-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -Command \"& { whoami; whoami /groups | Select-String 'Mandatory' } *> '" +
                    outFile.Replace("'", "''") + "'\"")
                { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
                using (var p = Process.Start(psi))
                {
                    while (!p.WaitForExit(100)) RhinoApp.Wait();
                    Log("P4 elevated child exit=" + p.ExitCode);
                }
                Log("P4 result file: " + (File.Exists(outFile) ? File.ReadAllText(outFile).Trim().Replace("\r\n", " / ") : "MISSING"));
                try { File.Delete(outFile); } catch { }
            }
            catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223)
            {
                Log("P4 UAC declined by user (1223)");
            }
            catch (Exception e) { Log("P4 FAILED: " + e.Message); }

            return Result.Success;
        }
    }
}
