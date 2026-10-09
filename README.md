# meshlink

RhinoMCP over SSH.

[中文](README.zh-CN.md)

Drive Rhino 8 on a Windows PC from an AI agent on your Mac (Codex, Claude Code and
other MCP clients) over the local network, without exposing Rhino's
unauthenticated bridge port to that network.

```
Mac                                        Windows PC
AI client ── rhinomcp ── 127.0.0.1:1999 ══ SSH ══► 127.0.0.1:1999 ── Rhino 8 + RhinoMCP plugin
```

The modeling tools come from [RhinoMCP](https://github.com/jingcheng-chen/rhinomcp).
This project covers the part RhinoMCP leaves to you: connecting the two machines
safely, and the setup problems that fail without an error message.

> **Status: early.** The [0.3.0-dev prerelease](https://github.com/rigelmansid/meshlink/releases/tag/v0.3.0-dev) is a demo: the
> `meshlink` command for the Mac (setup, pairing, Codex configuration, a
> read-only `doctor`) with its installer, and the meshlink Rhino plug-in for the
> PC. It has been tested on one Windows 10 PC with UAC off only. No stable
> release has been published yet. The project covers Rhino 8 only.

## Quick start

1. On the PC: install OpenSSH Server and, in Rhino 8, the RhinoMCP plugin. For
   OpenSSH Server, press **Win + R** and run `ms-settings:optionalfeatures` (or
   search Settings for "optional features"), then add **OpenSSH Server**. The
   menu path differs between Windows versions.
2. On the Mac, install meshlink with one command in Terminal:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/rigelmansid/meshlink/main/get.sh | bash
   ```

   It downloads the newest release, checks its SHA-256, installs into `~/.local`
   (no `sudo`) and adds `~/.local/bin` to your PATH; open a new terminal window
   afterwards. To read [get.sh](get.sh) first, download it and run `bash get.sh`.
   Without it: unpack a release (or clone this repository) and run `./install.sh`.
3. `meshlink setup --address <pc-address> --user <windows-user>`. It prints the
   command to run on the PC in an elevated PowerShell (`meshlink windows-script`
   shows where the script is), then checks the PC's host key with you.
4. `meshlink client codex`. It points Codex at `rhinomcp` on the PC and runs
   `meshlink doctor`.
5. Run `mcpstart` in Rhino and restart Codex.

`meshlink doctor` checks the whole link again at any time; `meshlink uninstall`
removes meshlink.

## Pairing

Instead of steps 3 to 5, the meshlink Rhino plug-in on the PC and `meshlink pair`
on the Mac can pair the two machines over the local network. Both screens show
the same six-digit code. Once both people confirm it, the plug-in installs the
Mac's SSH key (it runs `prepare-windows.ps1` as administrator), and the Mac checks
the PC's host key and adds a Host entry. Nothing changes on either machine
unless both confirm. The protocol is in [docs/pairing.md](docs/pairing.md).

So far this has been tested on one Windows 10 PC with UAC off. To try it:

1. Download `meshlink-<version>-rh8_17-win.yak` from the
   [0.3.0-dev prerelease](https://github.com/rigelmansid/meshlink/releases/tag/v0.3.0-dev). To build it yourself you need the .NET SDK and
   McNeel's [`yak` tool](https://developer.rhino3d.com/guides/yak/yak-cli-reference/):
   `YAK=/path/to/yak scripts/package-yak.sh` writes it into `dist/`.
2. On the PC, install OpenSSH Server and RhinoMCP as in step 1, then drag the
   `.yak` file onto Rhino 8 (8.17 or later) and restart Rhino.
3. On the Mac, run `meshlink pair`. Rhino shows the request within a few seconds.
   Compare the codes, choose the Windows account the Mac logs in as (a dedicated
   standard account is safer), and confirm on both sides.
4. Run `meshlink client codex`, as in step 4 above. From then on the plug-in runs
   `mcpstart` when Rhino opens; `MeshlinkOptions` in Rhino turns that off.

`MeshlinkUnpair` in Rhino removes the key a paired Mac was given. On the Mac,
delete the Host entry `meshlink pair` added to `~/.ssh/config`.

## What's here

| Path | What it is |
|---|---|
| [docs/remote-setup.md](docs/remote-setup.md) | **Start here.** Setup guide: Windows OpenSSH, the two connection options, troubleshooting, security. |
| [bin/meshlink](bin/meshlink) | The `meshlink` command. It only dispatches to the scripts below, which also run on their own. |
| [install.sh](install.sh), [uninstall.sh](uninstall.sh) | Install into `~/.local` (rerun to upgrade) and remove again. Neither touches `~/.ssh`; uninstall asks before removing Codex's entry. |
| [scripts/package.sh](scripts/package.sh) | Builds `dist/meshlink-<version>.tar.gz` and its SHA-256 file. |
| [get.sh](get.sh) | The one-line installer: finds the newest release, checks it, runs its `install.sh` and adds `~/.local/bin` to PATH. |
| [tests/test-get.sh](tests/test-get.sh) | Tests `get.sh` against a fake `curl` in a temporary home. |
| [tests/test-install.sh](tests/test-install.sh) | Tests packaging, install, upgrade, uninstall and the `meshlink` command in a temporary home. |
| [scripts/setup.sh](scripts/setup.sh) | First-time setup on the Mac: SSH key, a Host entry in `~/.ssh/config`, the exact command to run on the PC, the PC's host key checked against what the PC reports, and a test login. Never overwrites an existing key or Host entry. |
| [scripts/pair.sh](scripts/pair.sh) | `meshlink pair`: announces this Mac on the local network, takes the Rhino plug-in through the four steps of [docs/pairing.md](docs/pairing.md), and adds the Host entry once both sides have confirmed. |
| [scripts/client-codex.sh](scripts/client-codex.sh) | Points Codex's MCP entry at `rhinomcp` on the PC, then runs `doctor`. Edits `config.toml` in place: in an existing entry only the command and args lines change, so its other settings and every comment stay. Changing an existing, different entry needs a yes and makes a backup first. |
| [tests/test-setup.sh](tests/test-setup.sh) | Tests `setup.sh` and `client-codex.sh` in a temporary home with a fake `ssh` and `codex`. |
| [scripts/doctor.sh](scripts/doctor.sh) | Read-only check of the whole link, segment by segment, ending with one real tool call. Reads Codex's configuration; asks for nothing and changes nothing. |
| [tests/test-doctor.sh](tests/test-doctor.sh) | Tests `doctor.sh` against a fake `codex` and `ssh`; needs no Windows PC. |
| [scripts/prepare-windows.ps1](scripts/prepare-windows.ps1) | Run once on the PC in an elevated PowerShell: firewall, the Mac's key with the permissions sshd requires, `ClientAliveInterval`, uv and the pinned `rhinomcp`, then a report with the host key fingerprint. Safe to rerun; `-WhatIf` previews. Does not install OpenSSH Server or the Rhino plugin. |
| [tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md) | Manual test list for the Windows script (the Mac side only checks its syntax). |
| [rhino-plugin/](rhino-plugin) | The Rhino plug-in for pairing (C#, .NET 8), its pairing library, unit tests and a test driver. |
| [scripts/package-yak.sh](scripts/package-yak.sh) | Builds the plug-in's Yak package and its SHA-256 file into `dist/`. |
| [tests/test-pair.sh](tests/test-pair.sh) | Tests `pair.sh` against a fake plug-in, or with `PAIR_CLIENT=dotnet` against the plug-in's own pairing code. |
| [tests/rhino-plugin-checklist.md](tests/rhino-plugin-checklist.md) | Manual test list for the plug-in in Rhino. |
| [scripts/rhino-tunnel.sh](scripts/rhino-tunnel.sh) | Keeps the SSH port forward up: reconnects with backoff, refuses a busy port, warns when Codex's `RHINO_MCP_PORT` doesn't match, and stops (exit 3) when ssh may not use the network at all, as inside a sandbox. |
| [tests/test-rhino-tunnel.sh](tests/test-rhino-tunnel.sh) | Tests the tunnel script against a fake `ssh`; needs no Windows PC. |
| [experiments/](experiments/) | `mcp_stdio_probe.py`, a small MCP client for checking a server end to end, and the notes from testing Option 1. |
| [docs/project-notes.md](docs/project-notes.md) | Developer notes in Chinese: current status, todo list. Alongside it: the [roadmap](docs/roadmap.md), [decisions](docs/decisions.md), every [pitfall](docs/pitfalls.md) hit so far, and the [stage and verification log](docs/log.md). |
| [AGENTS.md](AGENTS.md) | Working rules for AI agents and contributors in this repository. |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version. |
| [.github/workflows/tests.yml](.github/workflows/tests.yml) | Runs every automated test on macOS for each push to `main` and each pull request. |

## Two ways to connect

Both use an SSH login from the Mac to the PC with a key. Rhino's port stays on
loopback on both machines.

- **Option 1: run the server over SSH (recommended).** The MCP client starts
  `ssh rhino-pc rhinomcp.exe`, so the server runs on the PC and talks to Rhino
  locally. Nothing keeps running between sessions. Needs `uv` and `rhinomcp` on
  the PC. In testing, Codex did not reconnect after a network drop; restarting
  it once the network was back fixed it.
- **Option 2: SSH port forward.** `rhinomcp` runs on the Mac and
  `scripts/rhino-tunnel.sh` forwards the port. The PC needs only the Rhino
  plugin and OpenSSH Server.

[docs/remote-setup.md](docs/remote-setup.md) has the step-by-step setup for both.

## Requirements

- **Mac:** macOS with `bash`, `ssh` and `lsof`, which ship with the system.
  Option 2 also needs [`uv`](https://docs.astral.sh/uv/) and `rhinomcp`.
- **Windows PC:** Windows 10 or 11 with OpenSSH Server, and Rhino 8 with the
  RhinoMCP plugin (**Tools → Package Manager → `rhinomcp`**).
- **An MCP client** such as Codex CLI or Claude Code.

Tested with macOS 26 (arm64), Windows 10 22H2, Rhino 8.35, rhinomcp 0.4.1.1 and
Codex CLI 0.155.1 to 0.159.3. Other versions are likely to work but haven't
been checked.

## Using the tunnel script (Option 2)

Set up the `rhino-pc` host in `~/.ssh/config` and accept its host key once with
`ssh rhino-pc`, as described in the guide. Then run `mcpstart` in Rhino and:

```sh
scripts/rhino-tunnel.sh        # leave it running; Ctrl-C to stop
```

It reads host, user, key and keepalives from `~/.ssh/config`. Settings are
environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `HOST` | `rhino-pc` | `~/.ssh/config` host entry |
| `LOCAL_PORT` | `1999` | Port on the Mac. If you change it, set `RHINO_MCP_PORT` in the client config to match |
| `REMOTE_PORT` | `1999` | Port Rhino listens on. Leave it as is |
| `CODEX_CONFIG` | `~/.codex/config.toml` | Config file checked for a mismatched `RHINO_MCP_PORT` |
| `BASE_DELAY` / `MAX_DELAY` | `5` / `60` | Reconnect backoff in seconds |

A connected MCP server doesn't prove Rhino is reachable. To check the whole
chain, ask the agent to call a read-only tool such as `get_document_summary`.

## Running the tests

```sh
tests/test-install.sh        # ~10 s
tests/test-get.sh            # ~8 s
tests/test-setup.sh          # ~4 s
tests/test-doctor.sh         # ~6 s, local ports 29941–29942
tests/test-rhino-tunnel.sh   # ~40 s, local ports 29931–29937
tests/test-pair.sh           # ~25 s, local ports 29951–29952
dotnet test rhino-plugin/Meshlink.Pairing.Tests   # needs the .NET SDK
```

They use a fake `ssh`, `codex` and `dns-sd` and a temporary home, and need
`python3`. They don't touch `~/.ssh`, Codex's config or any real host. GitHub
Actions runs them on macOS with the system bash 3.2. The
Windows script and the plug-in are tested by hand with
[tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md) and
[tests/rhino-plugin-checklist.md](tests/rhino-plugin-checklist.md).

## Security

Anyone who can use the SSH key can run any command as that Windows user.
RhinoMCP's code-execution tools can do the same through Rhino. The SSH key and
the Windows account are the real security boundary. A dedicated standard
(non-administrator) Windows account is a good idea. See the Security section of
the guide.

## License

[MIT](LICENSE). RhinoMCP is a separate project by Jingcheng Chen, also MIT.
This project is not affiliated with McNeel or with RhinoMCP.
