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

    /// <summary>
    /// Removes the key a Mac was given when it paired through this plug-in
    /// (D-25). Keys installed some other way (meshlink setup, by hand) are not
    /// listed and stay as they are.
    /// </summary>
    [Guid("FD727E24-C745-44AC-954F-C09EA70EFFFC")]
    public class MeshlinkUnpairCommand : Command
    {
        public override string EnglishName
        {
            get { return "MeshlinkUnpair"; }
        }

        protected override Result RunCommand(RhinoDoc doc, RunMode mode)
        {
            var settings = MeshlinkPlugin.Instance.Settings;
            var stored = settings.GetStringList(MeshlinkPlugin.PairedSetting, new string[0]);
            var macs = PairedMac.ReadAll(stored);
            if (macs.Count == 0)
            {
                MeshlinkPlugin.Log("no Mac has paired through this plug-in; keys installed another way are not listed here");
                return Result.Nothing;
            }
            var labels = macs.Select(m => m.Label).ToList();
            var picked = Rhino.UI.Dialogs.ShowListBox("meshlink: unpair a Mac",
                                                      "Remove the SSH key a Mac was given when it paired:", labels) as string;
            if (picked == null) return Result.Cancel;
            var mac = macs[labels.IndexOf(picked)];
            var answer = Rhino.UI.Dialogs.ShowMessage(
                string.Format("Remove the key of \"{0}\" from {1}? That Mac can then no longer log in as {1}. " +
                              "This runs prepare-windows.ps1 as administrator.", mac.Name, mac.Account),
                "meshlink: unpair", Rhino.UI.ShowMessageButton.YesNo, Rhino.UI.ShowMessageIcon.Question);
            if (answer != Rhino.UI.ShowMessageResult.Yes) return Result.Cancel;

            var run = ElevatedSetup.RunAsync(mac.Account, mac.Key, remove: true);
            while (!run.IsCompleted)
            {
                RhinoApp.Wait();
                Thread.Sleep(50);
            }
            if (run.IsFaulted)
            {
                MeshlinkPlugin.Log("unpairing failed: " + run.Exception.GetBaseException().Message);
                return Result.Failure;
            }
            var outcome = run.Result;
            if (outcome.Declined)
            {
                MeshlinkPlugin.Log("administrator approval was declined; nothing was changed");
                return Result.Cancel;
            }
            if (!outcome.Ok)
            {
                MeshlinkPlugin.Log("removing the key failed; prepare-windows.ps1 reported:");
                foreach (var line in outcome.Lines) MeshlinkPlugin.Log("  " + line);
                return Result.Failure;
            }
            settings.SetStringList(MeshlinkPlugin.PairedSetting, PairedMac.Remove(stored, mac));
            MeshlinkPlugin.Log(string.Format("removed the key of \"{0}\" from {1}. On the Mac, delete the Host entry " +
                                             "meshlink pair added to ~/.ssh/config.", mac.Name, mac.Account));
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
                // Esc: nothing is saved; say so, a changed toggle looks saved.
                MeshlinkPlugin.Log("options unchanged (press Enter to keep a change)");
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
