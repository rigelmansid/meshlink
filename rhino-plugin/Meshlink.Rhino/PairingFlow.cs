using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Eto.Drawing;
using Eto.Forms;
using Meshlink.Pairing;
using Rhino.UI;

namespace Meshlink.Plugin
{
    /// <summary>
    /// One pairing, from the Mac's offer to the result (docs/pairing.md).
    /// Nothing on this PC changes unless both people confirm the code: the
    /// one at the Mac (step 3) and the one here (Allow).
    /// </summary>
    sealed class PairingFlow
    {
        static PairingFlow active;
        static readonly Dictionary<string, PairingDialog> offers = new Dictionary<string, PairingDialog>();

        readonly MacOffer offer;
        readonly PairingDialog dialog;
        readonly CancellationTokenSource connecting = new CancellationTokenSource();
        readonly TaskCompletionSource<string> choice =
            new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);

        PairingFlow(MacOffer offer, PairingDialog dialog)
        {
            this.offer = offer;
            this.dialog = dialog;
        }

        /// <summary>A Mac was noticed offering to pair: ask whether to. UI thread.</summary>
        public static void Offer(MacOffer offer)
        {
            if (active != null || offers.ContainsKey(offer.Instance)) return;
            var dialog = new PairingDialog();
            offers[offer.Instance] = dialog;
            dialog.Closed += (sender, e) => offers.Remove(offer.Instance);
            dialog.ShowOffer(offer.Name, offer.EndPoint.Address.ToString(),
                             () => { offers.Remove(offer.Instance); Start(offer, dialog); },
                             () => dialog.Close());
            dialog.Show();
            MeshlinkPlugin.Log(string.Format("the Mac \"{0}\" ({1}) offers to pair", offer.Name, offer.EndPoint.Address));
        }

        /// <summary>The Mac stopped offering: drop its question if pairing has not begun.</summary>
        public static void Withdrawn(string instance)
        {
            PairingDialog dialog;
            if (!offers.TryGetValue(instance, out dialog)) return;
            offers.Remove(instance);
            dialog.Close();
        }

        /// <summary>Pair with offer now (MeshlinkPair).</summary>
        public static void Begin(MacOffer offer)
        {
            if (active != null)
            {
                MeshlinkPlugin.Log("another pairing is in progress");
                active.dialog.BringToFront();
                return;
            }
            Withdrawn(offer.Instance);
            var dialog = new PairingDialog();
            dialog.Show();
            Start(offer, dialog);
        }

        static void Start(MacOffer offer, PairingDialog dialog)
        {
            if (active != null)
            {
                dialog.ShowEnd("Another pairing is in progress.", null);
                return;
            }
            var flow = new PairingFlow(offer, dialog);
            active = flow;
            // Closing the window means no: before the code it stops connecting,
            // at the code it declines. Setup that has started runs to its end.
            dialog.Closed += (sender, e) =>
            {
                flow.connecting.Cancel();
                flow.choice.TrySetResult(null);
            };
            _ = flow.RunAsync();
        }

        void Ui(Action action)
        {
            Application.Instance.AsyncInvoke(() =>
            {
                if (!dialog.IsClosed) action();
            });
        }

        void End(string message, IEnumerable<string> details)
        {
            MeshlinkPlugin.Log(message);
            var lines = details == null ? null : details.ToList();
            Ui(() => dialog.ShowEnd(message, lines));
        }

        async Task RunAsync()
        {
            PairingSession session = null;
            Task<bool> macAnswer = null;
            try
            {
                var hostKey = HostKey.Read();
                Ui(() => dialog.ShowBusy("Connecting to " + offer.Name + "..."));
                session = await PairingSession.StartAsync(offer.EndPoint, hostKey, new PairingOptions(),
                                                          connecting.Token);
                var name = string.IsNullOrEmpty(session.MacName) ? offer.Name : session.MacName;
                var code = session.Code;
                Ui(() => dialog.ShowCode(name, code, Environment.UserName,
                                         account => choice.TrySetResult(account),
                                         () => choice.TrySetResult(null)));
                // Not tied to the window: a "no" from this side should still
                // reach a Mac that is waiting for it.
                macAnswer = session.WaitForMacAsync(CancellationToken.None);

                // Either person may answer first.
                if (await Task.WhenAny(choice.Task, macAnswer) == macAnswer)
                {
                    if (!await macAnswer)
                    {
                        End("The Mac did not confirm the pairing code. Nothing was changed.", null);
                        return;
                    }
                    Ui(() => dialog.NoteMacConfirmed());
                }
                var account = await choice.Task;
                if (account == null)
                {
                    End("Pairing declined. Nothing was changed.", null);
                    await TellMacAsync(session, macAnswer, PairingResult.Declined, null, "declined in Rhino on the PC");
                    return;
                }
                if (!macAnswer.IsCompleted) Ui(() => dialog.ShowBusy("Waiting for the Mac to confirm the code..."));
                if (!await macAnswer)
                {
                    End("The Mac did not confirm the pairing code. Nothing was changed.", null);
                    return;
                }

                Ui(() => dialog.ShowBusy("Setting up SSH for " + account +
                                         ". Windows may ask for administrator approval."));
                var setup = await ElevatedSetup.RunAsync(account, session.MacPublicKey);
                if (setup.Declined)
                {
                    End("Administrator approval was declined. Nothing was changed.", null);
                    await TellMacAsync(session, macAnswer, PairingResult.Declined, null,
                                       "administrator approval was declined on the PC");
                    return;
                }
                if (!setup.Ok)
                {
                    End("Setting up SSH failed; the Mac was told. prepare-windows.ps1 reported:", setup.Lines);
                    await TellMacAsync(session, macAnswer, PairingResult.Fail, null, setup.Notable().ToArray());
                    return;
                }
                await session.SendResultAsync(PairingResult.Ok, account, setup.Notable(), CancellationToken.None);
                MeshlinkPlugin.Instance.Settings.SetBool(MeshlinkPlugin.StartMcpSetting, true);
                End(string.Format("Paired with \"{0}\": it logs in as {1}. Rhino now starts the MCP listener " +
                                  "when it opens (MeshlinkOptions to change). On the Mac, finish with: " +
                                  "meshlink client codex", name, account), setup.Notable());
                Application.Instance.AsyncInvoke(Mcp.Start);
            }
            catch (OperationCanceledException)
            {
                MeshlinkPlugin.Log("pairing with \"" + offer.Name + "\" stopped: the window was closed");
            }
            catch (PairingException e)
            {
                End("Pairing failed: " + e.Message, null);
            }
            catch (Exception e)
            {
                End("Pairing failed: " + e.Message, new[] { e.ToString() });
            }
            finally
            {
                Application.Instance.AsyncInvoke(() => { if (active == this) active = null; });
            }
        }

        /// <summary>
        /// Tells a Mac that confirmed how it ended here, so it need not wait
        /// for its timeout. A Mac that is gone is left to that timeout.
        /// </summary>
        static async Task TellMacAsync(PairingSession session, Task<bool> macAnswer, PairingResult result,
                                       string user, params string[] messages)
        {
            try
            {
                if (await Task.WhenAny(macAnswer, Task.Delay(TimeSpan.FromMinutes(2))) != macAnswer) return;
                if (macAnswer.Status != TaskStatus.RanToCompletion || !macAnswer.Result) return;
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                    await session.SendResultAsync(result, user, messages, cts.Token);
            }
            catch (Exception)
            {
                // The Mac is gone; it gives up on its own.
            }
        }
    }

    sealed class PairingDialog : Form
    {
        const int TextWidth = 440;
        Label status;

        public PairingDialog()
        {
            Title = "meshlink: pair with a Mac";
            Resizable = false;
            Maximizable = false;
            AutoSize = true;
            Padding = new Padding(16);
            Owner = RhinoEtoApp.MainWindow;
            Closed += (sender, e) => IsClosed = true;
        }

        public bool IsClosed { get; private set; }

        public void ShowOffer(string name, string address, Action pair, Action ignore)
        {
            Set(Text(string.Format("The Mac \"{0}\" ({1}) offers to pair with this PC. Pairing lets it use Rhino " +
                                   "here over SSH.", name, address)),
                Buttons(Button("Ignore", ignore), Button("Pair...", pair)));
        }

        public void ShowBusy(string message)
        {
            Set(Text(message));
        }

        public void ShowCode(string name, string code, string account, Action<string> allow, Action deny)
        {
            var codeLabel = new Label { Text = code, Font = new Font(FontFamilies.Monospace, 28, FontStyle.Bold) };
            var accountBox = new TextBox { Text = account, Width = 220 };
            status = Text("");
            Set(Text("Pairing code:"),
                codeLabel,
                Text(string.Format("Allow only if the Mac \"{0}\" shows the same code.", name)),
                Text("Windows account the Mac logs in as (a dedicated standard account is safer):"),
                accountBox,
                Text("Allowing installs the Mac's SSH key for that account and adjusts this PC's SSH setup " +
                     "as administrator (prepare-windows.ps1)."),
                status,
                Buttons(Button("Deny", deny), Button("Allow", () =>
                {
                    var a = (accountBox.Text ?? "").Trim();
                    if (!Check.IsAccount(a))
                    {
                        status.Text = "Use a plain account name: letters, digits, '.', '_' or '-'.";
                        return;
                    }
                    ShowBusy("Allowed. Waiting for the Mac...");
                    allow(a);
                })));
        }

        public void NoteMacConfirmed()
        {
            if (status != null) status.Text = "The Mac has confirmed the code.";
        }

        public void ShowEnd(string message, IList<string> details)
        {
            var rows = new List<Control> { Text(message) };
            if (details != null && details.Count > 0)
                rows.Add(new TextArea
                {
                    Text = string.Join(Environment.NewLine, details),
                    ReadOnly = true,
                    Wrap = false,
                    Width = TextWidth,
                    Height = 160,
                });
            rows.Add(Buttons(Button("Close", Close)));
            Set(rows.ToArray());
        }

        void Set(params Control[] rows)
        {
            var layout = new StackLayout { Spacing = 10, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            foreach (var row in rows) layout.Items.Add(row);
            Content = layout;
        }

        static Label Text(string text)
        {
            return new Label { Text = text, Wrap = WrapMode.Word, Width = TextWidth };
        }

        static Button Button(string text, Action click)
        {
            var b = new Button { Text = text };
            b.Click += (sender, e) => click();
            return b;
        }

        static Control Buttons(params Button[] buttons)
        {
            var row = new StackLayout { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Items.Add(new StackLayoutItem(null, true));
            foreach (var b in buttons) row.Items.Add(b);
            return row;
        }
    }
}
