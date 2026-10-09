<#
.SYNOPSIS
Prepares a Windows PC so a Mac can run RhinoMCP on it over SSH (Option 1).

.DESCRIPTION
Run on the PC in an elevated Windows PowerShell 5.1. Safe to run again: every
step checks first and changes only what is missing. Add -WhatIf to see what it
would change without changing anything.

What it does:
  - checks OpenSSH Server is installed, starts it, sets it to start with Windows
  - makes sure an inbound firewall rule allows TCP 22
  - installs the Mac's public key for -User, in the file and with the
    permissions sshd requires (it silently ignores the key otherwise)
  - sets ClientAliveInterval / ClientAliveCountMax in sshd_config, above any
    Match block, checks the file with `sshd -t` and restarts sshd; a backup is
    kept next to the file
  - installs uv and the pinned rhinomcp when -User is the account running this
    script; for another account it checks and prints the commands to run as it
  - reports UAC, whether Rhino is listening, the host key fingerprint to
    compare on the Mac, and this PC's addresses

What it does not do: install OpenSSH Server (that can hang when Windows Update
is blocked), install the Rhino plugin, run mcpstart, or create accounts.

The file is ASCII only: Windows PowerShell 5.1 reads a file without a BOM in
the system code page.

.PARAMETER User
Local account the Mac logs in as. Defaults to the account running the script.
A dedicated standard account is recommended (docs/remote-setup.md, Security).
It must have logged in once so that its profile folder exists.

.PARAMETER PublicKey
The Mac's public key: the one line in ~/.ssh/<key>.pub.

.PARAMETER RhinoMcpVersion
The rhinomcp version to install. Keep it equal to the Rhino plugin's version.

.PARAMETER SshdConfig
The sshd_config to edit. Only for testing on a copy: sshd is restarted only
when this is the live file.

.PARAMETER RemoveKey
Remove -PublicKey from -User's key file instead, and change nothing else:
sshd, the firewall and sshd_config stay as they are. Used by the meshlink
Rhino plug-in's MeshlinkUnpair; safe to run when the key is not there.

.PARAMETER ResultFile
Also write the outcome to this file, for a caller that cannot read this
window: the meshlink Rhino plug-in starts the script elevated when a Mac
pairs (docs/pairing.md). UTF-8 without BOM; the lines are "RESULT ok" or
"RESULT fail", "USER <account>", then "LINE <text>" for each report line.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\prepare-windows.ps1 -User rhino-agent -PublicKey "ssh-ed25519 AAAA... mac" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$User = $env:USERNAME,
  [Parameter(Mandatory = $true)][string]$PublicKey,
  [string]$RhinoMcpVersion = '0.4.1.1',
  [int]$RhinoPort = 1999,
  [string]$SshdConfig = (Join-Path $env:ProgramData 'ssh\sshd_config'),
  [switch]$RemoveKey,
  [string]$ResultFile = ''
)

Set-StrictMode -Version 2.0
# Not 'Stop': in Windows PowerShell 5.1 a native command writing to a
# redirected stderr raises an error record, which 'Stop' turns into a crash.
# Cmdlets that must succeed get -ErrorAction Stop inside try blocks instead.
$ErrorActionPreference = 'Continue'

$script:fails = 0
$script:warns = 0
$script:lines = New-Object System.Collections.Generic.List[string]
$dryRun = [bool]$WhatIfPreference

# Under -WhatIf, modules that load on first use print a "What if: Set Alias"
# line for every alias they define. Load them up front with WhatIf off.
$WhatIfPreference = $false
Import-Module CimCmdlets, NetSecurity, NetTCPIP, Microsoft.PowerShell.LocalAccounts -ErrorAction SilentlyContinue
$WhatIfPreference = $dryRun

function Report([string]$tag, [string]$msg) { Line ('[{0}] {1}' -f $tag, $msg) }
function Line([string]$text) { Write-Host $text; $script:lines.Add($text) }
function Ok([string]$m)   { Report ' OK ' $m }
function Done([string]$m) { Report 'DONE' $m }
function Info([string]$m) { Report 'INFO' $m }
function Warn([string]$m) { Report 'WARN' $m; $script:warns++ }
function Fail([string]$m) { Report 'FAIL' $m; $script:fails++ }
function Skip([string]$m) { Report 'SKIP' $m }
function Hint([string]$m) { Line ('       -> {0}' -f $m) }

function Finish {
  Write-Host ''
  if ($dryRun) { Write-Host 'WhatIf: nothing was changed.' }
  $result = 'ok'
  if ($script:fails -gt 0) {
    $result = 'fail'
    Write-Host ('prepare-windows: {0} failed, {1} warning(s)' -f $script:fails, $script:warns)
  } else {
    Write-Host ('prepare-windows: done, {0} warning(s)' -f $script:warns)
  }
  if ($ResultFile) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('RESULT ' + $result)
    $out.Add('USER ' + $User)
    foreach ($l in $script:lines) { $out.Add('LINE ' + $l) }
    try {
      [IO.File]::WriteAllLines($ResultFile, $out.ToArray(), (New-Object Text.UTF8Encoding($false)))
    } catch {
      Write-Host ('could not write {0}: {1}' -f $ResultFile, $_.Exception.Message)
    }
  }
  if ($result -eq 'fail') { exit 1 }
  exit 0
}

$SID_ADMINS = 'S-1-5-32-544'
$SID_SYSTEM = 'S-1-5-18'

# ---------------------------------------------------------------- 0. context
# Check the arguments before anything is changed.
$key = $PublicKey.Trim()
if ($key -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) ([A-Za-z0-9+/=]+)( .*)?$') {
  $keyBody = $Matches[3]
} else {
  Fail 'that does not look like an SSH public key line'
  Hint 'pass the single line from the Mac: cat ~/.ssh/<key>.pub'
  Finish
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'this needs an elevated PowerShell'
  Hint 'right-click Windows PowerShell > Run as administrator, then run this again'
  Finish
}
if ($RemoveKey) {
  Info ('removing this key for {0}; sshd, the firewall and sshd_config are left alone' -f $User)
}
# Removing a key never restarts sshd.
if ($env:SSH_CONNECTION -and -not $RemoveKey) {
  Warn 'running over SSH: if sshd has to be restarted, this session will drop'
}

# Steps 1 and 2 prepare the PC; removing a key needs neither.
if (-not $RemoveKey) {
  # ------------------------------------------------------- 1. OpenSSH Server
  $svc = Get-Service sshd -ErrorAction SilentlyContinue
  if (-not $svc) {
    Fail 'OpenSSH Server is not installed'
    Hint 'press Win+R, run ms-settings:optionalfeatures, add OpenSSH Server, then run this again'
    Hint 'Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 also works, but can hang for a long time when Windows Update is blocked'
    Finish
  }
  if ($svc.StartType -ne 'Automatic') {
    if ($PSCmdlet.ShouldProcess('sshd', 'set startup type to Automatic')) {
      Set-Service sshd -StartupType Automatic
      Done 'sshd starts with Windows'
    }
  } else {
    Ok 'sshd starts with Windows'
  }
  # sshd writes its host keys and the default sshd_config on first start, so it
  # has to run before the config can be edited.
  if ($svc.Status -ne 'Running') {
    if ($PSCmdlet.ShouldProcess('sshd', 'start')) {
      try {
        Start-Service sshd -ErrorAction Stop
        Done 'sshd started'
      } catch {
        Fail ('sshd does not start: {0}' -f $_.Exception.Message)
        Finish
      }
    }
  } else {
    Ok 'sshd is running'
  }

  $sshdExe = $null
  $svcInfo = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
  if ($svcInfo -and $svcInfo.PathName) { $sshdExe = $svcInfo.PathName.Trim().Trim('"') }
  if (-not $sshdExe -or -not (Test-Path $sshdExe)) { $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe' }
  $sshDir = Split-Path $sshdExe

  # ------------------------------------------------------------- 2. firewall
  $fw = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
          Where-Object { $_.LocalPort -eq '22' } |
          Get-NetFirewallRule -ErrorAction SilentlyContinue |
          Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
  if ($fw.Count -gt 0) {
    Ok ('firewall allows inbound TCP 22 ({0})' -f $fw[0].Name)
  } elseif ($PSCmdlet.ShouldProcess('Windows Firewall', 'allow inbound TCP 22 for sshd')) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
      -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Done 'firewall rule sshd added for inbound TCP 22'
  }
}

# -------------------------------------------------------------- 3. account
try {
  $acct = Get-LocalUser -Name $User -ErrorAction Stop
} catch {
  Fail ('no local account named {0}' -f $User)
  Hint 'create it first (docs/remote-setup.md, Security), or pass -User <name>'
  Finish
}
$sid = $acct.SID.Value
$isCurrent = ($sid -eq $me.User.Value)

# Get-LocalGroupMember throws on some machines (orphaned or Azure AD members);
# `net localgroup` with the group's localized name is the fallback.
$isAdmin = $null
try {
  $isAdmin = [bool](Get-LocalGroupMember -SID $SID_ADMINS -ErrorAction Stop |
                    Where-Object { $_.SID.Value -eq $sid })
} catch {
  $groupName = (New-Object Security.Principal.SecurityIdentifier($SID_ADMINS)).Translate(
                 [Security.Principal.NTAccount]).Value.Split('\')[-1]
  $members = net localgroup "$groupName" 2>$null
  if ($LASTEXITCODE -eq 0) { $isAdmin = [bool]($members | Where-Object { $_.Trim() -eq $User }) }
}
if ($isAdmin -eq $null) {
  Fail ('cannot tell whether {0} is an administrator' -f $User)
  Finish
}
if ($isAdmin -and -not $RemoveKey) {
  Warn ('{0} is an administrator: the SSH key will give a fully elevated shell' -f $User)
  Hint 'a dedicated standard account for SSH is recommended (docs/remote-setup.md, Security)'
} elseif ($isAdmin) {
  Ok ('{0} is an administrator: its keys are in administrators_authorized_keys' -f $User)
} else {
  Ok ('{0} is a standard account' -f $User)
}

$profilePath = $null
$prof = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
if ($prof) { $profilePath = $prof.LocalPath }

# ---------------------------------------------------------- 4. public key
# Administrators share one key file; everyone else uses their own profile.
if ($isAdmin) {
  $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
  $allowed = @($SID_ADMINS, $SID_SYSTEM)
} else {
  if (-not $profilePath -and $RemoveKey) {
    Ok ('{0} has no profile folder, so it has no key to remove' -f $User)
    Finish
  }
  if (-not $profilePath) {
    Fail ('{0} has never logged in, so it has no profile folder yet' -f $User)
    Hint ('run: runas /user:{0} cmd   (enter its password, close the window), then run this again' -f $User)
    Finish
  }
  $keyFile = Join-Path $profilePath '.ssh\authorized_keys'
  $allowed = @($sid, $SID_ADMINS, $SID_SYSTEM)
}

$present = (Test-Path $keyFile) -and
           [bool](Get-Content $keyFile -ErrorAction SilentlyContinue | Where-Object { $_ -match [regex]::Escape($keyBody) })
if ($RemoveKey) {
  if (-not $present) {
    Ok ('the key is not in {0}' -f $keyFile)
  } elseif ($PSCmdlet.ShouldProcess($keyFile, 'remove the public key')) {
    $keep = @(Get-Content $keyFile | Where-Object { $_ -notmatch [regex]::Escape($keyBody) })
    # Rewrite the same file, so its permissions stay as they are (pitfall 2).
    [IO.File]::WriteAllLines($keyFile, [string[]]$keep, (New-Object Text.ASCIIEncoding))
    Done ('key removed from {0}' -f $keyFile)
  }
} elseif ($present) {
  Ok ('key already in {0}' -f $keyFile)
} elseif ($PSCmdlet.ShouldProcess($keyFile, 'add the public key')) {
  $dir = Split-Path $keyFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $prefix = ''
  if ((Test-Path $keyFile) -and (Get-Item $keyFile).Length -gt 0) {
    $bytes = [IO.File]::ReadAllBytes($keyFile)
    if ($bytes[-1] -ne 10) { $prefix = "`r`n" }
  }
  [IO.File]::AppendAllText($keyFile, $prefix + $key + "`r`n", (New-Object Text.ASCIIEncoding))
  Done ('key added to {0}' -f $keyFile)
}

# sshd ignores a key file that anyone else can access, without saying so
# (pitfall 2). Reset to exactly the allowed entries, by SID so localized group
# names do not matter.
function Test-KeyAcl([string]$path, [string[]]$sids) {
  try {
    $aces = (Get-Acl $path -ErrorAction Stop).Access
    foreach ($ace in $aces) {
      $s = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
      if ($sids -notcontains $s) { return $false }
    }
    return (@($aces).Count -eq $sids.Count)
  } catch { return $false }
}
if (-not (Test-Path $keyFile)) {
  if ($dryRun) { Skip 'key file permissions (the file does not exist yet)' }
} elseif (Test-KeyAcl $keyFile $allowed) {
  Ok 'key file permissions are what sshd requires'
} elseif ($PSCmdlet.ShouldProcess($keyFile, 'restrict permissions')) {
  $grants = @($allowed | ForEach-Object { '*{0}:F' -f $_ })
  icacls $keyFile /reset | Out-Null
  icacls $keyFile /inheritance:r /grant $grants | Out-Null
  if ($LASTEXITCODE -eq 0 -and (Test-KeyAcl $keyFile $allowed)) {
    Done 'key file permissions restricted'
  } else {
    Fail ('could not set permissions on {0}' -f $keyFile)
    Hint ('check with: icacls "{0}"' -f $keyFile)
  }
}

if ($RemoveKey) { Finish }

# ------------------------------------------------------- 5. sshd_config
# Without ClientAliveInterval, a dropped network leaves rhinomcp running on
# this PC (pitfall 16). Settings after the first Match line only apply inside
# that block, and the default file ends with one, so never append blindly.
$wanted = [ordered]@{ ClientAliveInterval = '15'; ClientAliveCountMax = '3' }
if (-not (Test-Path $SshdConfig)) {
  Fail ('{0} not found' -f $SshdConfig)
  Finish
}
$raw = [IO.File]::ReadAllText($SshdConfig)
$nl = "`n"
if ($raw.Contains("`r`n")) { $nl = "`r`n" }
$lines = New-Object System.Collections.Generic.List[string]
$lines.AddRange([string[]]($raw -split "`r?`n"))
$changes = @()

function First-Match {
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Match\s') { return $i } }
  return $lines.Count
}
foreach ($name in $wanted.Keys) {
  $value = $wanted[$name]
  $end = First-Match
  $active = -1; $commented = -1
  for ($i = 0; $i -lt $end; $i++) {
    if ($active -lt 0 -and $lines[$i] -match "^\s*$name\s+(\S+)") { $active = $i; $current = $Matches[1] }
    if ($commented -lt 0 -and $lines[$i] -match "^\s*#\s*$name(\s|$)") { $commented = $i }
  }
  if ($active -ge 0) {
    if ($name -eq 'ClientAliveInterval' -and $current -eq '0') {
      $lines[$active] = "$name $value"; $changes += "$name 0 -> $value"
    }
  } elseif ($commented -ge 0) {
    $lines[$commented] = "$name $value"; $changes += "$name $value (was commented out)"
  } else {
    $lines.Insert($end, "$name $value"); $changes += "$name $value (added above any Match block)"
  }
}

$liveConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
$isLive = ((Resolve-Path $SshdConfig).Path -eq (Resolve-Path $liveConfig -ErrorAction SilentlyContinue).Path)
if ($changes.Count -eq 0) {
  Ok 'sshd_config has ClientAliveInterval and ClientAliveCountMax above any Match block'
} elseif ($PSCmdlet.ShouldProcess($SshdConfig, ('set ' + ($changes -join ', ')))) {
  $backup = '{0}.bak-{1}' -f $SshdConfig, (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $SshdConfig $backup
  # Overwrite the content in place: replacing the file would drop its ACL.
  [IO.File]::WriteAllText($SshdConfig, ($lines -join $nl), (New-Object Text.UTF8Encoding($false)))
  & $sshdExe -t -f $SshdConfig 2>$null
  if ($LASTEXITCODE -ne 0) {
    Copy-Item $backup $SshdConfig -Force
    Fail ('sshd -t rejected the edited file; the original was restored from {0}' -f $backup)
    Finish
  }
  Done ('sshd_config: {0} (backup: {1})' -f ($changes -join ', '), (Split-Path $backup -Leaf))
  if ($isLive) {
    if ($PSCmdlet.ShouldProcess('sshd', 'restart to apply sshd_config')) {
      try {
        Restart-Service sshd -ErrorAction Stop
        Done 'sshd restarted'
      } catch {
        Fail ('sshd did not restart: {0}' -f $_.Exception.Message)
        Hint ('restore the backup and start it: Copy-Item "{0}" "{1}" -Force; Start-Service sshd' -f $backup, $SshdConfig)
        Finish
      }
    }
  } else {
    Info ('{0} is not the live config; sshd was not restarted' -f $SshdConfig)
  }
}
if ($isLive -and -not $dryRun) {
  $eff = & $sshdExe -T 2>$null | Where-Object { $_ -match '^clientalive' }
  if ($eff) { Info ('sshd reads: {0}' -f ($eff -join ', ')) }
}

# --------------------------------------------------- 6. uv and rhinomcp
$rhinomcp = $null
if ($profilePath) { $rhinomcp = Join-Path $profilePath '.local\bin\rhinomcp.exe' }

if ($isCurrent) {
  $uv = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
  if (-not (Test-Path $uv)) {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { $uv = $cmd.Source }
  }
  if (Test-Path $uv) {
    Ok ('uv found at {0}' -f $uv)
  } elseif ($PSCmdlet.ShouldProcess('uv', 'install from https://astral.sh/uv/install.ps1')) {
    powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex'
    $uv = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path $uv) { Done 'uv installed' } else { Fail 'uv did not install'; Finish }
  }
  if (Test-Path $uv) {
    $tools = & $uv tool list 2>$null
    if ($tools -match ('^rhinomcp v{0}$' -f [regex]::Escape($RhinoMcpVersion))) {
      Ok ('rhinomcp {0} installed' -f $RhinoMcpVersion)
    } elseif ($PSCmdlet.ShouldProcess('rhinomcp', ('install version {0} with uv' -f $RhinoMcpVersion))) {
      & $uv tool install --force ('rhinomcp=={0}' -f $RhinoMcpVersion)
      $tools = & $uv tool list 2>$null
      if ($tools -match ('^rhinomcp v{0}$' -f [regex]::Escape($RhinoMcpVersion))) {
        Done ('rhinomcp {0} installed' -f $RhinoMcpVersion)
      } else {
        Fail ('rhinomcp {0} did not install' -f $RhinoMcpVersion)
      }
    }
  }
} elseif ($rhinomcp -and (Test-Path $rhinomcp)) {
  Ok ('rhinomcp.exe found for {0} (version not checked from here)' -f $User)
} else {
  Skip ('installing uv and rhinomcp for {0}: it has to run as that account' -f $User)
  Hint ('runas /user:{0} powershell    then, in the window that opens:' -f $User)
  Hint 'powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"'
  Hint ('& $HOME\.local\bin\uv.exe tool install rhinomcp=={0}' -f $RhinoMcpVersion)
}

# ---------------------------------------------------------------- 7. report
$lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
if ($lua -eq 0) {
  Warn 'UAC is off: code run through Rhino has full administrator rights, whatever account SSH uses'
  Hint 'see docs/remote-setup.md, Security'
} else {
  Ok 'UAC is on'
}

$listen = @(Get-NetTCPConnection -LocalPort $RhinoPort -State Listen -ErrorAction SilentlyContinue)
if ($listen.Count -gt 0) {
  Info ('Rhino listens on {0}:{1}' -f $listen[0].LocalAddress, $RhinoPort)
} else {
  Info ('nothing listens on port {0} now; run mcpstart in Rhino before using it' -f $RhinoPort)
}

$hostKey = Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub'
$keygen = Join-Path $sshDir 'ssh-keygen.exe'
if ((Test-Path $hostKey) -and (Test-Path $keygen)) {
  $fp = (& $keygen -lf $hostKey 2>$null) -split ' '
  if ($fp.Count -ge 2) { Info ('host key {0} (ED25519): the first ssh from the Mac must show this' -f $fp[1]) }
}

$addrs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
           ForEach-Object { $_.IPAddress })
if ($addrs.Count -gt 0) { Info ('this PC: {0}  (use one as HostName in the Mac''s ~/.ssh/config)' -f ($addrs -join ', ')) }

# The account belongs in the Mac's Host entry (meshlink setup writes it), so
# the command Codex runs carries no -l.
if ($rhinomcp) {
  Info ('rhinomcp.exe for {0}: {1}' -f $User, $rhinomcp)
  Info ('next, on the Mac: meshlink client codex --host <host>, where <host> logs in as {0}' -f $User)
  Info ('Codex then runs: ssh -T -o BatchMode=yes <host> "set RHINO_MCP_TIMEOUT=30&& {0}"' -f $rhinomcp)
}

Finish
