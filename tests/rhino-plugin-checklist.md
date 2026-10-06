# Manual test: the meshlink Rhino plug-in

The plug-in (`rhino-plugin/Meshlink.Rhino`) is built and its pairing code is
tested on the Mac (`dotnet test rhino-plugin/Meshlink.Pairing.Tests`, and
`PAIR_CLIENT=dotnet tests/test-pair.sh` against the real `pair.sh`). Loading it
in Rhino, its dialogs, elevation and `mcpstart` can only be checked by hand on
the PC. Run this list after every change to the plug-in. Record the result,
date, Rhino and Windows versions, and whether UAC is on in `docs/log.md`
(verification records).

## Setup

On the Mac, build and copy the whole output folder to the PC:

```sh
dotnet build rhino-plugin/Meshlink.Rhino -c Release
# copy rhino-plugin/Meshlink.Rhino/bin/Release/net8.0/ to the PC, all files together
```

In Rhino 8 on the PC, drag `Meshlink.rhp` into the window once. rhinomcp must
be installed (Package Manager).

Pair under a test alias with a test key, so the working Host entry and key stay
as they are, and give Codex a temporary config:

```sh
bin/meshlink pair --host <test-alias> --key ~/.ssh/id_ed25519_pairtest
export CODEX_HOME=$(mktemp -d)   # for R7 and R8 only
```

`<agent>` is the dedicated standard account (D-13); it must have logged in once.

## Cases

| # | Do | Expected |
|---|---|---|
| R1 | Load `Meshlink.rhp`. | No error. `MeshlinkPair` and `MeshlinkOptions` exist. |
| R2 | On the Mac, run the `meshlink pair` line above. | Within about 10 s Rhino shows "The Mac ... offers to pair". No firewall dialog on either computer. |
| R3 | Ignore. Stop `meshlink pair` (Ctrl-C) and run it again. | The dialog closes; the second run is offered again. |
| R4 | Pair..., compare the codes, Deny; on the Mac answer `yes`. | Mac: "declined on the PC; nothing was written". `authorized_keys` of `<agent>` unchanged. |
| R5 | Pair..., then answer `no` on the Mac. | Rhino: "The Mac did not confirm the pairing code. Nothing was changed." |
| R6 | Pair..., same code on both, `yes` on the Mac, Allow with account `<agent>`. | A PowerShell window runs and closes (with UAC on, Windows asks first). Rhino: "Paired with ...". Mac: key installed for `<agent>`, the PC presents the paired host key, Host entry added, `ssh <test-alias> logs in as <agent>`. |
| R7 | `bin/meshlink client codex --host <test-alias>`, then `bin/meshlink doctor`. | doctor ends with a read-only MCP call that succeeds. |
| R8 | Restart Rhino, then `bin/meshlink doctor` again. | Command line: `[meshlink] started the MCP listener (mcpstart)` or `already running`. doctor succeeds. |
| R9 | `meshlink pair` on the Mac again (new alias), then `MeshlinkPair` in Rhino instead of the offer. | Same dialog as R6, without the offer step. Deny it. |
| R10 | `MeshlinkOptions` ListenForPairing=Off; `meshlink pair` on the Mac. | No offer appears; `MeshlinkPair` still finds the Mac. Set it back to On. |
| R11 | With UAC on (another PC, see project-notes §7): R6, once allowing and once refusing the UAC prompt. | Refused: "Administrator approval was declined. Nothing was changed."; Mac: "declined on the PC". |

## Clean up

- Mac: remove the `Host <test-alias>` entry from `~/.ssh/config` (a backup
  `config.bak-*` is next to it) and `~/.ssh/id_ed25519_pairtest*`; delete
  `$CODEX_HOME`.
- PC: remove the line with the test key from `<agent>`'s `authorized_keys`
  (match it by the base64 in `~/.ssh/id_ed25519_pairtest.pub`; other keys may
  carry the same `meshlink` comment).
- `MeshlinkOptions` StartMcpOnLaunch=Off if Rhino should not start the listener.

## Covered on the original PC (2026-10-06)

R1 to R10 on the original Windows 10 PC (UAC off, desktop account an
administrator), pairing the dedicated account, which already had rhinomcp; see
`docs/log.md`, verification records. Cleaned up afterwards as above.

## Not covered yet

UAC on (R11); a PC where the paired account is the one running Rhino and has no
rhinomcp yet (the script then installs uv and rhinomcp for it); two PCs with the
plug-in on one network; Windows 11.
