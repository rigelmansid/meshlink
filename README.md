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

> **Status: early.** What exists today is a tested setup guide, the `meshlink`
> command for the Mac (setup, Codex configuration, a read-only `doctor`), a
> Windows preparation script, an installer, and tests. No release has been
> published yet. The project covers Rhino 8 only.

## Quick start

1. On the PC: install OpenSSH Server (**Settings → Apps → Optional features**)
   and, in Rhino 8, the RhinoMCP plugin.
2. On the Mac, from an unpacked release or a clone of this repository:
   `./install.sh`. It installs into `~/.local` and needs no `sudo`.
3. `meshlink setup --address <pc-address> --user <windows-user>`. It prints the
   command to run on the PC in an elevated PowerShell (`meshlink windows-script`
   shows where the script is), then checks the PC's host key with you.
4. `meshlink client codex`. It points Codex at `rhinomcp` on the PC and runs
   `meshlink doctor`.
5. Run `mcpstart` in Rhino and restart Codex.

`meshlink doctor` checks the whole link again at any time; `meshlink uninstall`
removes meshlink.

## What's here

| Path | What it is |
|---|---|
| [docs/remote-setup.md](docs/remote-setup.md) | **Start here.** Setup guide: Windows OpenSSH, the two connection options, troubleshooting, security. |
| [bin/meshlink](bin/meshlink) | The `meshlink` command. It only dispatches to the scripts below, which also run on their own. |
| [install.sh](install.sh), [uninstall.sh](uninstall.sh) | Install into `~/.local` (rerun to upgrade) and remove again. Neither touches `~/.ssh`; uninstall asks before removing Codex's entry. |
| [scripts/package.sh](scripts/package.sh) | Builds `dist/meshlink-<version>.tar.gz` and its SHA-256 file. |
| [tests/test-install.sh](tests/test-install.sh) | Tests packaging, install, upgrade, uninstall and the `meshlink` command in a temporary home. |
| [scripts/setup.sh](scripts/setup.sh) | First-time setup on the Mac: SSH key, a Host entry in `~/.ssh/config`, the exact command to run on the PC, the PC's host key checked against what the PC reports, and a test login. Never overwrites an existing key or Host entry. |
| [scripts/client-codex.sh](scripts/client-codex.sh) | Points Codex's MCP entry at `rhinomcp` on the PC, then runs `doctor`. Replacing an existing, different entry needs a yes and makes a backup first: `codex mcp add` drops that entry's other settings and the comments in `config.toml`. |
| [tests/test-setup.sh](tests/test-setup.sh) | Tests `setup.sh` and `client-codex.sh` in a temporary home with a fake `ssh` and `codex`. |
| [scripts/doctor.sh](scripts/doctor.sh) | Read-only check of the whole link, segment by segment, ending with one real tool call. Reads Codex's configuration; asks for nothing and changes nothing. |
| [tests/test-doctor.sh](tests/test-doctor.sh) | Tests `doctor.sh` against a fake `codex` and `ssh`; needs no Windows PC. |
| [scripts/prepare-windows.ps1](scripts/prepare-windows.ps1) | Run once on the PC in an elevated PowerShell: firewall, the Mac's key with the permissions sshd requires, `ClientAliveInterval`, uv and the pinned `rhinomcp`, then a report with the host key fingerprint. Safe to rerun; `-WhatIf` previews. Does not install OpenSSH Server or the Rhino plugin. |
| [tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md) | Manual test list for the Windows script (there is no PowerShell on the Mac side). |
| [scripts/rhino-tunnel.sh](scripts/rhino-tunnel.sh) | Keeps the SSH port forward up: reconnects with backoff, refuses a busy port, warns when Codex's `RHINO_MCP_PORT` doesn't match. |
| [tests/test-rhino-tunnel.sh](tests/test-rhino-tunnel.sh) | Tests the tunnel script against a fake `ssh`; needs no Windows PC. |
| [experiments/](experiments/) | `mcp_stdio_probe.py`, a small MCP client for checking a server end to end, and the notes from testing Option 1. |
| [docs/project-notes.md](docs/project-notes.md) | Developer notes in Chinese: current status, todo list, roadmap. Alongside it: [decisions](docs/decisions.md), every [pitfall](docs/pitfalls.md) hit so far, and the [stage and verification log](docs/log.md). |
| [AGENTS.md](AGENTS.md) | Working rules for AI agents and contributors in this repository. |

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
tests/test-setup.sh          # ~4 s
tests/test-doctor.sh         # ~6 s, local ports 29941–29942
tests/test-rhino-tunnel.sh   # ~40 s, local ports 29931–29936
```

They use a fake `ssh` and `codex` and a temporary home, and need `python3`.
They don't touch `~/.ssh`, Codex's config or any real host. The Windows script
is tested by hand with [tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md).

## Security

Anyone who can use the SSH key can run any command as that Windows user.
RhinoMCP's code-execution tools can do the same through Rhino. The SSH key and
the Windows account are the real security boundary. A dedicated standard
(non-administrator) Windows account is a good idea. See the Security section of
the guide.

## License

[MIT](LICENSE). RhinoMCP is a separate project by Jingcheng Chen, also MIT.
This project is not affiliated with McNeel or with RhinoMCP.
