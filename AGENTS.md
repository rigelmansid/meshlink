<!-- profile: code -->
# AGENTS.md

Working rules for AI agents (Claude Code, Codex and others) and maintainers of
this repository. `CLAUDE.md` is a symlink to this file; edit `AGENTS.md` only.

This file says *how to work*. Project content lives in `docs/`, all in Chinese:

- [project-notes.md](docs/project-notes.md): 进行中 (work in progress), current
  status, architecture, config, daily use, §7 todo list. Section numbers (§)
  below refer to this file.
- [roadmap.md](docs/roadmap.md): first-release scope, product shape, phases,
  open questions and risks.
- [decisions.md](docs/decisions.md): decisions D-1 onward, with their reasons.
- [pitfalls.md](docs/pitfalls.md): pitfalls 坑 1–21.
- [log.md](docs/log.md): stage log and verification records.
- [pairing.md](docs/pairing.md): the 0.2 pairing protocol (draft).

Do not copy project content into this file.

## Getting started

1. Read project-notes 进行中 and the §7 todo list, and restate the state to the
   user before changing anything. Decide whether the task is development or
   restoring a working setup.
2. Restoring a setup: check environment, config and startup against §2–§4, then
   make one read-only Rhino tool call (see Verification).
3. Before changing tunnel logic: read the related decisions (D-1, D-4, D-10)
   and pitfalls (坑 8–13), and run the existing tests.
4. What exists: the `meshlink` command (`bin/meshlink`, subcommands `setup`,
   `pair`, `client codex`, `doctor`, `windows-script`, `tunnel`, `uninstall`,
   `version`), which dispatches to the scripts under `scripts/`;
   `install.sh` / `uninstall.sh`; `scripts/package.sh`; and
   `scripts/prepare-windows.ps1`. `pair` is the Mac side of pairing
   (docs/pairing.md). `rhino-plugin/` holds the Windows side: the Rhino
   plug-in (`Meshlink.rhp`, commands `MeshlinkPair`, `MeshlinkUnpair`,
   `MeshlinkOptions`), its pairing library, tests and a test driver;
   `scripts/package-yak.sh` builds its Yak package locally. Pairing has been
   tested on the original PC (tests/rhino-plugin-checklist.md lists what is
   covered). Anything listed as planned in project-notes (published releases,
   a package on the public Yak server, other clients) does not exist yet;
   never describe it as existing or invent its interface.
5. `setup`, `client codex`, `install.sh` and `uninstall.sh` write to the user's
   `~/.ssh`, Codex config or `~/.local`; run them on the real machine only when
   the user asks. Their tests use a temporary home.
6. To check a working setup, run `meshlink doctor` (or `scripts/doctor.sh`)
   first; it is read-only.

## Commands

```sh
bash -n scripts/rhino-tunnel.sh      # syntax check
bash -n tests/test-rhino-tunnel.sh
tests/test-rhino-tunnel.sh           # ~40 s, expects "passed: 24  failed: 0"
bash -n scripts/doctor.sh
tests/test-doctor.sh                 # ~6 s, expects "passed: 48  failed: 0"
tests/test-setup.sh                  # ~5 s, expects "passed: 85  failed: 0"
tests/test-install.sh                # ~10 s, expects "passed: 39  failed: 0"
tests/test-pair.sh                   # ~25 s, expects "passed: 118  failed: 0"
scripts/package.sh                   # builds dist/ (git-ignored); test-install removes it

dotnet test rhino-plugin/Meshlink.Pairing.Tests       # ~10 s, expects "Passed: 62"
dotnet build rhino-plugin/Meshlink.Pairing.Driver -c Release
PAIR_CLIENT=dotnet tests/test-pair.sh                  # ~20 s, expects "passed: 98  failed: 0"
dotnet build rhino-plugin/Meshlink.Rhino -c Release   # the plug-in, for Rhino on the PC
YAK=<path to yak> scripts/package-yak.sh               # dist/meshlink-<version>-rh8_17-win.yak
```

`yak` is McNeel's standalone tool; on the maintainer's Mac it is
`../materials/scratch/tools/yak` (D-24). Pushing a package to the public Yak
server is an outward-facing step that needs the user's explicit go.

The tests need `python3`, `lsof`, `pgrep`, `ps` and free local ports
29931–29936 (tunnel), 29941–29942 (doctor) and 29951–29952 (pair); check the
ports are free before running. They use a fake `ssh`, `codex` and `dns-sd`
and, where they write files, a temporary home; they never touch `~/.ssh`,
`~/.local`, the Codex config, a real host or port 1999. A test that reads `$?` after a function must not run that
function on the right of a pipe (it runs in a subshell; see `test-install.sh` I7). Assertion T4a is
timing-sensitive and can flake on a busy machine; rerun before assuming a
regression.

`scripts/prepare-windows.ps1` has no automated run, only a syntax check in
`Meshlink.Pairing.Tests`: run `tests/prepare-windows-checklist.md` by hand on
Windows after every change. Keep the file ASCII only (Windows PowerShell 5.1
reads a file without a BOM in the system code page) and compatible with
PowerShell 5.1 (the test rejects PowerShell 7-only operators). Never run it on
the user's PC yourself; it changes system configuration. The plug-in runs it
elevated when a Mac pairs (`-ResultFile`).

The .NET projects under `rhino-plugin/` need the .NET SDK (D-21); the tests and
the driver roll forward to a newer runtime than .NET 8. The plug-in has no
automated test inside Rhino: run `tests/rhino-plugin-checklist.md` by hand on
the PC after every change, and never load it on the user's PC yourself. Its
network input is untrusted: keep checking every value read from the Mac
(`Meshlink.Pairing.Check`) before it reaches a file or a command line.

Probe any MCP stdio server end to end:

```sh
python3 experiments/mcp_stdio_probe.py --call get_document_summary -- <server command...>
experiments/mcp_stdio_probe.sh get_document_summary -- <server command...>   # bash 3.2, no Python
```

There is no build step, package manifest or CI.

## Changing `scripts/rhino-tunnel.sh`

Each rule below prevents a real, silent failure. The reasons are in the script
comments and in the pitfalls cited. Do not "simplify" them away.

- Write both ends of `-L` as `127.0.0.1` (坑 10).
- Keep `-o BatchMode=yes` and `-o ExitOnForwardFailure=yes`. The daemon must never
  prompt; first host-key acceptance is a manual `ssh rhino-pc` (D-4).
- ssh and the backoff `sleep` run in the background and are awaited with
  `wait`, under one `trap cleanup INT TERM HUP` (坑 12).
- Detect a tunnel by port (`lsof -nP -iTCP:<port> -sTCP:LISTEN`), never by
  process name (坑 9).
- Classify backoff by whether the local port ever bound, not by duration
  alone (坑 12).
- Keep `LOCAL_PORT` and `REMOTE_PORT` separate; `PORT=` must keep failing with
  exit code 2 (坑 11).
- Host, user, key and keepalives come only from `~/.ssh/config`; do not restate
  them in the script.
- Stay compatible with macOS's system bash 3.2: no associative arrays,
  `mapfile`, `${var,,}` and the like.
- Add or update a scenario in `tests/test-rhino-tunnel.sh` with every
  behaviour change. Add tests alongside the feature, not before a release.
- After touching the `trap` line, tell the user a real terminal Ctrl-C must be
  checked by hand: the harness cannot deliver SIGINT and uses a group SIGHUP.

## Working with a live Rhino

- **Do not start `rhino-tunnel.sh` yourself** (坑 13). If a tool call returns
  `Could not connect to Rhino at 127.0.0.1:1999`, tell the user to run
  `mcpstart` in Rhino and start the tunnel, or to use the SSH stdio option. In a
  sandbox without network the script retries forever. If you did start one,
  stop it with SIGTERM and confirm the port is free.
- `codex exec` does not expose MCP tools (坑 15); use the interactive TUI or
  `experiments/mcp_stdio_probe.py`.
- Modeling safety:
  - Delete only objects your task created, identified by layer or user string.
    An "empty-looking" document is not permission to bulk-delete.
  - One tool call is one undo step: rhinomcp 0.4.1.1 wraps every
    non-read-only command, script execution included, in an undo record
    named `MCP: <command>`. Do not open another inside a script; it would not
    start (D-28). Check this again after a rhinomcp upgrade (pitfall 14).
  - Never overwrite an existing `.3dm` file; save under a new name.
- Never write modeling scripts, generated models or scratch files into the
  repository. Put them in the maintainer's `../materials/scratch/` (outside
  the repository, next to it; it may not exist on other machines). Reference
  material is in `../materials/refs/` and unsorted material in
  `../materials/inbox/`; read them only when the task needs them (D-15).

## Verification

- A client showing the server as "connected", or a listening tunnel port,
  proves nothing about Rhino (坑 8, 坑 11). The only end-to-end check is one
  read-only tool call such as `get_document_summary`.
- Passing simulated tests covers the fake `ssh` only. Never report a real
  Windows/Rhino result unless it happened in this session.
- Record every result with date and time, environment and versions, the
  method, and its limits. Keep "verified now" separate from "historical" and
  "not re-checked", and say which steps were skipped.
- Versions change without notice (坑 14). Re-verify after upgrades instead of
  reusing old compatibility claims.

## Keeping docs current

- Record a decision in `docs/decisions.md` when it is made, not at the end:
  next D-number, date, "用户决定" or "agent 选择", then 背景 / 选项 / 选择 /
  理由 / 影响 (see D-14). This covers choices the user makes and non-obvious
  choices an agent makes; not pure implementation detail. Cite the number in
  rules, code comments and commit bodies (`Why: D-14`).
- When a decision changes, add a new entry that says what it replaces and mark
  the old heading "（已被 D-n 替代）"; keep troubleshooting knowledge that is
  still useful.
- After a unit of work: overwrite the 进行中 block in project-notes (task,
  where it stopped, decisions, what needs the user, next steps, what not to
  repeat; at most 15 lines); update 当前状态 and 验证现状 and the §7 todo list;
  append a row to the stage log in `docs/log.md` and, for real checks, to its
  verification records. Do not write a separate handoff file.
- 当前状态 holds only the latest snapshot. Move outdated conclusions into
  `docs/log.md` with their date.
- Maintain each config and procedure in one place and link to it rather than
  repeating it.
- Append new pitfalls to `docs/pitfalls.md` with the next number.
- When splicing a file by line numbers (awk/sed/head/tail), check that every
  number is set and numeric, write to a temporary file, and compare line counts
  before replacing the original. An empty variable once made awk delete 867
  lines of project-notes (2026-10-02; restored from `HEAD` before commit).
  Prefer locating text by heading over line numbers.
- Planning: when an open item is settled, update its status in
  `docs/roadmap.md`, record a decision, move actionable next steps into §7 and
  results into `docs/log.md`.
- The files under `docs/` (except `remote-setup.md`) and the experiment notes
  stay in Chinese. User-facing docs are
  English, with `README.zh-CN.md` kept in sync with `README.md`.
  `docs/remote-setup.md` mirrors upstream PR #63; keep the two consistent.
- Write plain, factual prose. Commit subjects are short imperative English.

## Privacy and publishing

- `private-notes.md` is git-ignored and holds real hosts, usernames and
  personal config. Never copy its content into tracked files, commit messages
  or PRs. Use the placeholders `<pc-address>`, `<windows-user>`, `<mac-user>`
  and `<user>`.
- Before any commit, check that no real IP, username or home path slipped in,
  e.g. `git ls-files | xargs grep -nE "192\.168|/Users/[a-z]"`, and that no
  U+FFFD replacement character was written into Chinese text (pitfall 20):
  `git ls-files | xargs grep -nI $'\xef\xbf\xbd'` must print nothing.
- Local `main` history contains personal data and must **never be pushed**. It
  is kept as an archive. Why: early commits still contain a real IP and
  usernames in their files, and every commit's author is the machine's default
  identity; pushing sends the whole history, and pushed data cannot be reliably
  taken back. The full reasoning is in `docs/decisions.md` D-8. The same holds for
  the local branch `public-presquash` (the `public` history before it was
  squashed for going public).
- Work continues on the `public` branch, which started as a fresh orphan commit
  and tracks `origin/main` of the public repository `rigelmansid/meshlink`.
  Push only `public`, and only on the user's explicit instruction. Everything
  pushed is public: run the checks above on every commit being pushed.
- Commits on `public` use the identity `Cheng Yuan` with the GitHub noreply
  address (set in this repository's git config), never the machine's default.
