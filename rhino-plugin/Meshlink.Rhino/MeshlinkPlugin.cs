using System;
using System.Runtime.InteropServices;
using Meshlink.Pairing;
using Rhino;
using Rhino.PlugIns;

[assembly: Guid("F9D3FAE8-C39C-4D9D-B405-7F597DE0D608")]

namespace Meshlink.Plugin
{
    public class MeshlinkPlugin : PlugIn
    {
        public const string ListenSetting = "ListenForPairing";
        public const string StartMcpSetting = "StartMcpOnLaunch";

        readonly DiscoveryWatcher watcher = new DiscoveryWatcher();

        public MeshlinkPlugin()
        {
            Instance = this;
        }

        public static MeshlinkPlugin Instance { get; private set; }

        /// <summary>
        /// Loaded with Rhino, so that a Mac offering to pair is noticed and the
        /// MCP listener starts without anyone typing a command.
        /// </summary>
        public override PlugInLoadTime LoadTime
        {
            get { return PlugInLoadTime.AtStartup; }
        }

        public bool Listening
        {
            get { return watcher.Running; }
        }

        protected override LoadReturnCode OnLoad(ref string errorMessage)
        {
            if (!OperatingSystem.IsWindows())
            {
                errorMessage = "meshlink pairs a Windows PC with a Mac; it does nothing on this system.";
                return LoadReturnCode.ErrorNoDialog;
            }
            watcher.Found += offer => RhinoApp.InvokeOnUiThread(new Action(() => PairingFlow.Offer(offer)));
            watcher.Gone += instance => RhinoApp.InvokeOnUiThread(new Action(() => PairingFlow.Withdrawn(instance)));
            watcher.Problem += message => RhinoApp.InvokeOnUiThread(new Action(() => Log("cannot look for Macs: " + message)));
            RhinoApp.Closing += (sender, e) => watcher.Stop();
            if (Settings.GetBool(ListenSetting, true)) watcher.Start();
            if (Settings.GetBool(StartMcpSetting, false)) Mcp.StartWhenIdle();
            return LoadReturnCode.Success;
        }

        public void SetListening(bool on)
        {
            Settings.SetBool(ListenSetting, on);
            if (on) watcher.Start();
            else watcher.Stop();
        }

        public static void Log(string message)
        {
            RhinoApp.WriteLine("[meshlink] " + message);
        }
    }
}
