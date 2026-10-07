using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Meshlink.Pairing;

namespace Meshlink.Plugin
{
    sealed class SetupOutcome
    {
        /// <summary>Administrator approval (UAC) was refused; nothing ran.</summary>
        public bool Declined;

        /// <summary>What the script reported; null if it reported nothing.</summary>
        public SetupReport Report;

        /// <summary>Why there is no report.</summary>
        public string Problem;

        public bool Ok { get { return Report != null && Report.Ok; } }

        public List<string> Lines
        {
            get { return Report != null ? Report.Lines : new List<string> { "[FAIL] " + Problem }; }
        }

        public List<string> Notable()
        {
            return Report != null ? Report.Notable() : Lines;
        }
    }

    static class HostKey
    {
        /// <summary>This PC's sshd host key, the one the Mac is to trust.</summary>
        public static string Read()
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                                    "ssh", "ssh_host_ed25519_key.pub");
            try
            {
                return File.ReadAllText(path);
            }
            catch (Exception e) when (e is FileNotFoundException || e is DirectoryNotFoundException)
            {
                throw new PairingException("this PC has no SSH host key yet (" + path + "): install OpenSSH Server " +
                                           "(Settings > Apps > Optional features) and start the sshd service once, then pair again");
            }
            catch (UnauthorizedAccessException)
            {
                throw new PairingException("cannot read this PC's SSH host key (" + path + ")");
            }
        }
    }

    /// <summary>
    /// Installs a paired Mac's key by running prepare-windows.ps1 elevated
    /// (docs/pairing.md), or removes it again (-RemoveKey, MeshlinkUnpair).
    /// With UAC on, Windows asks for approval; with UAC off it does not, and
    /// the plug-in's own dialog was the only question (D-22).
    /// </summary>
    static class ElevatedSetup
    {
        const int ErrorCancelled = 1223;

        public static Task<SetupOutcome> RunAsync(string account, string macKey, bool remove = false)
        {
            if (!Check.IsAccount(account) || !Check.IsPublicKey(macKey))
                throw new ArgumentException("account or key not checked before setup");
            return Task.Run(() => Run(account, macKey, remove));
        }

        static SetupOutcome Run(string account, string macKey, bool remove)
        {
            var outcome = new SetupOutcome();
            var bundled = Path.Combine(Path.GetDirectoryName(typeof(ElevatedSetup).Assembly.Location),
                                       "prepare-windows.ps1");
            if (!File.Exists(bundled))
            {
                outcome.Problem = "prepare-windows.ps1 is missing next to the meshlink plug-in";
                return outcome;
            }
            // Run a local copy: the plug-in may have been loaded from a network
            // share, which an elevated process does not necessarily see.
            var dir = Path.Combine(Path.GetTempPath(), "meshlink-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var script = Path.Combine(dir, "prepare-windows.ps1");
                File.Copy(bundled, script);
                var result = Path.Combine(dir, "result.txt");
                // account and key were checked: no quotes or spaces can break out.
                var args = string.Format(
                    "-NoProfile -ExecutionPolicy Bypass -File \"{0}\" -User {1} -PublicKey \"{2} meshlink\" -ResultFile \"{3}\"{4}",
                    script, account, macKey, result, remove ? " -RemoveKey" : "");
                var psi = new ProcessStartInfo("powershell.exe", args)
                {
                    UseShellExecute = true,
                    Verb = "runas",
                    // Visible: what runs as administrator should be seen.
                    WindowStyle = ProcessWindowStyle.Normal,
                };
                int exit;
                try
                {
                    using (var p = Process.Start(psi))
                    {
                        p.WaitForExit();
                        exit = p.ExitCode;
                    }
                }
                catch (Win32Exception e) when (e.NativeErrorCode == ErrorCancelled)
                {
                    outcome.Declined = true;
                    return outcome;
                }
                if (!File.Exists(result))
                {
                    outcome.Problem = "prepare-windows.ps1 ended (exit " + exit + ") without reporting a result";
                    return outcome;
                }
                outcome.Report = SetupReport.Parse(File.ReadAllLines(result, Encoding.UTF8));
                return outcome;
            }
            finally
            {
                try { Directory.Delete(dir, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
