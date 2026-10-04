using System.Runtime.InteropServices;

[assembly: Guid("B23BFA84-FD8B-4C33-B95D-0A60C29D0BD1")]

namespace MeshlinkProbe
{
    public class MeshlinkProbePlugin : Rhino.PlugIns.PlugIn
    {
        public MeshlinkProbePlugin() { Instance = this; }
        public static MeshlinkProbePlugin Instance { get; private set; }
    }
}
