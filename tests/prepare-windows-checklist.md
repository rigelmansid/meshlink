# Manual test: scripts/prepare-windows.ps1

There is no PowerShell on the Mac side, so this script is tested by hand on the
Windows PC. Run the whole list after every change to the script and on every
Windows version you want to claim support for. Record the result, date,
Windows build and PowerShell version in `docs/project-notes.md`.

## Setup

Copy the script to the PC (for example to `C:\Users\Public`), open an elevated
Windows PowerShell there, and set:

```powershell
$k = "<the Mac's public key line>"
$run = "powershell -NoProfile -ExecutionPolicy Bypass -File .\prepare-windows.ps1"
```

`<agent>` below is the dedicated standard account; it must have logged in once.

## Cases

| # | Command | Expected |
|---|---|---|
| A | `iex "$run -User <agent> -PublicKey '$k' -WhatIf"` | Every step reports its state; any change shows as a `What if:` line; ends with `WhatIf: nothing was changed.` No other `What if:` lines (module aliases). |
| B | `iex "$run -User <agent> -PublicKey '$k'"`, then the same again | First run applies what A listed (`[DONE]`). The second run has no `[DONE]` lines. `[INFO] sshd reads: clientaliveinterval 15, clientalivecountmax 3`. |
| C | `Copy-Item <an sshd_config with the two settings commented out> $env:TEMP\sshd_test_config`, then `iex "$run -User <agent> -PublicKey '$k' -SshdConfig $env:TEMP\sshd_test_config"`, then `Select-String -Path $env:TEMP\sshd_test_config -Pattern "ClientAlive\|^Match"` | `[DONE] sshd_config: ... (was commented out)` with a backup name; `[INFO] ... is not the live config; sshd was not restarted`. Both settings sit on their original lines, above the `Match` line. |
| D | `iex "$run -User $env:USERNAME -PublicKey '$k' -WhatIf"` (an administrator) | `[WARN] ... is an administrator`; key checked in `administrators_authorized_keys`; uv and rhinomcp checked for the current account. |
| E | `iex "$run -PublicKey 'not-a-key'"` | `[FAIL] that does not look like an SSH public key line` before any other step; exit code 1. |

After B, from the Mac: compare the `host key` fingerprint the script printed
with `ssh-keygen -lF <HostName>`, and run `scripts/doctor.sh`.

## Not covered yet

These paths have only been read, not run, because the test PC was already set
up. Run them on a fresh PC or VM before claiming they work:

- OpenSSH Server missing, stopped, or not set to start automatically
- no firewall rule for TCP 22
- key not yet present: creating `.ssh`, appending, resetting permissions
- `administrators_authorized_keys` with extra permission entries
- an account that has never logged in (no profile)
- `sshd_config` without commented defaults (insert above `Match`), and a
  restart of the live sshd
- installing uv and rhinomcp from scratch, or replacing another rhinomcp version
- `Get-LocalGroupMember` failing and the `net localgroup` fallback
