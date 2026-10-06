using System;
using System.Linq;
using System.Net.NetworkInformation;
using Rhino;

namespace Meshlink.Plugin
{
    /// <summary>Starting rhinomcp's listener (its mcpstart command).</summary>
    static class Mcp
    {
        // rhinomcp's default; the Mac side reaches it as 127.0.0.1:1999 (D-1).
        const int Port = 1999;

        public static bool Listening()
        {
            try
            {
                return IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(e => e.Port == Port);
            }
            catch (NetworkInformationException)
            {
                return false;
            }
        }

        /// <summary>Runs mcpstart once Rhino has finished starting.</summary>
        public static void StartWhenIdle()
        {
            EventHandler once = null;
            once = (sender, e) =>
            {
                RhinoApp.Idle -= once;
                Start();
            };
            RhinoApp.Idle += once;
        }

        public static void Start()
        {
            if (Listening())
            {
                MeshlinkPlugin.Log("the MCP listener is already running on port " + Port);
                return;
            }
            // Rhino says "Unknown command" itself when rhinomcp is not installed.
            RhinoApp.RunScript("_mcpstart", false);
            MeshlinkPlugin.Log("started the MCP listener (mcpstart); turn this off with MeshlinkOptions");
        }
    }
}
