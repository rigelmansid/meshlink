# Manual test: scripts/prepare-windows.ps1

There is no PowerShell on the Mac side, so this script is tested by hand on the
Windows PC. Run the whole list after every change to the script and on every
Windows version you want to claim support for. Record the result, date,
Windows build and PowerShell version in `docs/log.md` (verification records).

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

## Covered on an existing PC (2026-10-02)

Run on the original Windows 10 PC with a new standard account (see
`docs/log.md`, verification records): an account that has never logged
in; a new key into a new profile (`.ssh` created, permissions accepted); the
printed `runas` steps installing uv and rhinomcp for that account; sshd stopped
and set to manual; `sshd_config` without the commented defaults (insert above
`Match`, on a copy).

## Not covered yet

Run these on a fresh PC or VM before claiming they work:

- OpenSSH Server not installed
- no inbound rule for TCP 22 at all. Before disabling rules for this case, list
  every rule on port 22 (`Get-NetFirewallPortFilter -Protocol TCP | Where-Object
  LocalPort -eq 22 | Get-NetFirewallRule`) and restore exactly those afterwards:
  on 2026-10-02 a second rule named `sshd` already existed, so the "add a rule"
  path did not run and the cleanup removed the user's own rule (restored by hand)
- `administrators_authorized_keys` with extra permission entries
- editing the live `sshd_config` and restarting the live sshd
- installing uv and rhinomcp for the account running the script, from scratch,
  or replacing another rhinomcp version
- `Get-LocalGroupMember` failing and the `net localgroup` fallback
- Windows 11
