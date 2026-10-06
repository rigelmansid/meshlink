using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Meshlink.Pairing;
using Rhino;
using Rhino.Commands;
using Rhino.Input;
using Rhino.Input.Custom;

namespace Meshlink.Plugin
{
    /// <summary>
    /// Looks for a Mac running "meshlink pair" and pairs with it. The same
    /// happens without this command when Rhino notices such a Mac by itself
    /// (MeshlinkOptions ListenForPairing).
    /// </summary>
    [Guid("A2907393-4DBA-446B-8E59-9AFB097B7B60")]
    public class MeshlinkPairCommand : Command
    {
        public override string EnglishName
        {
            get { return "MeshlinkPair"; }
        }

        protected override Result RunCommand(RhinoDoc doc, RunMode mode)
        {
            MeshlinkPlugin.Log("looking for a Mac offering to pair (on the Mac: meshlink pair)...");
            var find = Task.Run(() => Discovery.FindAsync(TimeSpan.FromSeconds(4), CancellationToken.None));
            while (!find.IsCompleted)
            {
                RhinoApp.Wait();
                Thread.Sleep(50);
            }
            if (find.IsFaulted)
            {
                MeshlinkPlugin.Log("could not look for Macs: " + find.Exception.GetBaseException().Message);
                return Result.Failure;
            }
            var offers = find.Result;
            if (offers.Count == 0)
            {
                MeshlinkPlugin.Log("no Mac is offering to pair; on the Mac, run: meshlink pair");
                return Result.Nothing;
            }
            var offer = offers[0];
            if (offers.Count > 1)
            {
                var labels = offers.Select(o => o.Name + "  (" + o.EndPoint.Address + ")").ToList();
                var picked = Rhino.UI.Dialogs.ShowListBox("Pair with a Mac", "Several Macs offer to pair. Which one?",
                                                                  labels) as string;
                if (picked == null) return Result.Cancel;
                offer = offers[labels.IndexOf(picked)];
            }
            PairingFlow.Begin(offer);
            return Result.Success;
        }
    }

    [Guid("CCF0B9E5-2811-47E1-A155-531B878D461A")]
    public class MeshlinkOptionsCommand : Command
    {
        public override string EnglishName
        {
            get { return "MeshlinkOptions"; }
        }

        protected override Result RunCommand(RhinoDoc doc, RunMode mode)
        {
            var plugin = MeshlinkPlugin.Instance;
            var listen = new OptionToggle(plugin.Settings.GetBool(MeshlinkPlugin.ListenSetting, true), "Off", "On");
            var startMcp = new OptionToggle(plugin.Settings.GetBool(MeshlinkPlugin.StartMcpSetting, false), "Off", "On");
            var go = new GetOption();
            go.SetCommandPrompt("meshlink options (Enter when done)");
            go.AcceptNothing(true);
            go.AddOptionToggle("ListenForPairing", ref listen);
            go.AddOptionToggle("StartMcpOnLaunch", ref startMcp);
            while (true)
            {
                var r = go.Get();
                if (r == GetResult.Option) continue;
                if (r == GetResult.Nothing) break;
                return Result.Cancel;
            }
            plugin.SetListening(listen.CurrentValue);
            plugin.Settings.SetBool(MeshlinkPlugin.StartMcpSetting, startMcp.CurrentValue);
            MeshlinkPlugin.Log(string.Format("ListenForPairing={0}, StartMcpOnLaunch={1}",
                                             listen.CurrentValue ? "On" : "Off", startMcp.CurrentValue ? "On" : "Off"));
            return Result.Success;
        }
    }
}
