#!/usr/bin/env bash
# Read-only health check for the Mac -> Windows Rhino MCP link.
#
# Everything is derived from what Codex will actually run: `codex mcp get
# <server> --json` gives the command, its arguments and env. Nothing is asked
# for and nothing is written. Each check prints one line:
#
#   [ OK ]  passed            [WARN]  works, but see the note
#   [FAIL]  broken            [SKIP]  not checked (needs an earlier check)
#
# and a failure is followed by an indented "->" line with the next step.
# Exit status is 1 if anything failed, 0 otherwise; warnings do not count.
#
# Usage:  scripts/doctor.sh
#         SERVER=other scripts/doctor.sh     # a different MCP server name
#
# Only the final MCP round trip proves the link (pitfall 8): a listening port,
# a working SSH login or "connected" in /mcp each prove one segment only.
set -uo pipefail

# Settings come from the environment; the only option is --help.
case ${1:-} in
  "") ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

SERVER="${SERVER:-rhino}"
TIMEOUT="${TIMEOUT:-30}"
TOOL=get_document_summary

PROG=doctor
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

# ------------------------------------------------------------ 1. local tools
if ! command -v ssh >/dev/null 2>&1; then
  fail "ssh not found on this Mac"
  finish
fi
if ! command -v codex >/dev/null 2>&1; then
  fail "codex not found in PATH"
  hint "install Codex CLI, or open a new terminal if it was just installed"
  skip "everything else (needs Codex's configuration)"
  finish
fi
if ! codex_version=$(codex --version 2>/dev/null); then
  fail "codex is installed but does not run"
  hint "a half-finished upgrade can do this (pitfall 14); reinstall Codex"
  skip "everything else (needs Codex's configuration)"
  finish
fi
ok "$codex_version"

# ------------------------------------------------------- 2. codex mcp entry
if ! read_codex_server "$SERVER"; then
  fail "Codex has no MCP server named '$SERVER'"
  hint "add one with $CMD_CLIENT (or see docs/remote-setup.md, Option 1), or set SERVER=<name>"
  skip "everything else (needs Codex's configuration)"
  finish
fi
command=$CODEX_COMMAND
args=(${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"})
envs=(${CODEX_ENVS[@]+"${CODEX_ENVS[@]}"})

if [[ -z $command ]]; then
  fail "could not read the command for '$SERVER' from Codex (not a stdio server?)"
  skip "everything else (needs Codex's configuration)"
  finish
fi

if [[ $(basename "$command") == ssh ]]; then
  mode=ssh
  ok "'$SERVER' runs the server on Windows over SSH (Option 1)"
else
  mode=local
  ok "'$SERVER' runs a local server: $command (Option 2, port forward)"
fi

# ------------------------------------------------------------ Option 2 path
# rhinomcp runs on this Mac and dials RHINO_MCP_HOST:RHINO_MCP_PORT, which the
# tunnel script forwards. Only the local side is checked here.
if [[ $mode == local ]]; then
  port=1999
  for kv in ${envs[@]+"${envs[@]}"}; do
    case $kv in
      RHINO_MCP_PORT=*) port=${kv#*=} ;;
      RHINO_MCP_HOST=*)
        [[ ${kv#*=} == 127.0.0.1 || ${kv#*=} == localhost ]] ||
          warn "RHINO_MCP_HOST is ${kv#*=}: the bridge has no authentication, keep it on 127.0.0.1" ;;
    esac
  done
  # Probe by port, never by process name (pitfall 9); a wildcard bind puts the
  # unauthenticated bridge on the network (pitfall 10).
  listen=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u)
  if [[ -z $listen ]]; then
    fail "nothing listens on local port $port, so the tunnel is not running"
    hint "start $CMD_TUNNEL in its own terminal window"
    skip "MCP round trip (needs the tunnel)"
    finish
  fi
  if printf '%s\n' "$listen" | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
    fail "local port $port is bound beyond loopback: $(echo $listen)"
    hint "the bridge has no authentication; restart the tunnel with 127.0.0.1 on both ends of -L"
  else
    ok "tunnel listens on 127.0.0.1:$port"
  fi
  skip "Windows-side checks (Option 2 is only checked locally)"
fi

# ------------------------------------------------------------ Option 1 path
if [[ $mode == ssh ]]; then
  # Split ssh's own options from the destination and the remote command.
  ssh_opts=()
  host=""
  user=""
  remote=""
  has_T=no
  has_batch=no
  i=0
  n=${#args[@]}
  while ((i < n)); do
    a=${args[i]}
    case $a in
      -T) has_T=yes; ssh_opts+=("$a") ;;
      -o)
        ((i + 1 < n)) && v=${args[i + 1]} || v=""
        [[ $(printf '%s' "$v" | tr 'A-Z' 'a-z' | tr -d ' ') == batchmode=yes ]] && has_batch=yes
        ssh_opts+=("$a" "$v"); i=$((i + 1)) ;;
      -o*)
        [[ $(printf '%s' "${a#-o}" | tr 'A-Z' 'a-z' | tr -d ' ') == batchmode=yes ]] && has_batch=yes
        ssh_opts+=("$a") ;;
      -l) user=${args[i + 1]:-}; ssh_opts+=("$a" "$user"); i=$((i + 1)) ;;
      -[BbcDEeFIiJLmOpQRSWw])
        ssh_opts+=("$a" "${args[i + 1]:-}"); i=$((i + 1)) ;;
      -*) ssh_opts+=("$a") ;;
      *)
        host=$a
        remote="${args[*]:i+1}"
        break ;;
    esac
    i=$((i + 1))
  done

  if [[ -z $host ]]; then
    fail "could not find the SSH destination in Codex's arguments"
    skip "everything else (needs the SSH destination)"
    finish
  fi
  if [[ $user == "" && $host == *@* ]]; then
    user=${host%@*}
  fi
  # Usually the account comes from the Host entry in ~/.ssh/config.
  if [[ -z $user ]]; then
    user=$(ssh ${ssh_opts[@]+"${ssh_opts[@]}"} -G "$host" 2>/dev/null | awk '$1 == "user" {print $2; exit}')
  fi
  who=${user:+$user@}${host#*@}

  # ---------------------------------------------------------- 3. ssh flags
  [[ $has_T == yes ]] ||
    warn "Codex's ssh arguments lack -T; a terminal can corrupt the MCP stream"
  [[ $has_batch == yes ]] ||
    warn "Codex's ssh arguments lack -o BatchMode=yes; a password or host-key prompt would hang the client"

  # Every ssh that doctor runs itself is non-interactive and bounded.
  # (${a[@]+...}: bash 3.2 under set -u rejects "${a[@]}" for an empty array.)
  doctor_ssh=(ssh ${ssh_opts[@]+"${ssh_opts[@]}"} -o BatchMode=yes -o ConnectTimeout=10 "$host")

  # ---------------------------------------------------------- 4. ssh login
  out=$("${doctor_ssh[@]}" "echo doctor-ok" 2>&1)
  rc=$?
  if ((rc != 0)) || [[ $out != *doctor-ok* ]]; then
    msg=$(printf '%s\n' "$out" | grep -v '^\*\*' | readable | tail -3)
    fail "ssh $who failed (exit $rc)"
    case $msg in
      *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
        hint "the PC's host key is unknown or changed; run 'ssh $host' once by hand and check the fingerprint" ;;
      *"Permission denied"*)
        hint "the key was refused; check where the public key is on Windows and its permissions (pitfalls 2 and 5)" ;;
      *"Could not resolve hostname"*)
        hint "the host name does not resolve; check HostName in ~/.ssh/config" ;;
      *"Operation not permitted"*)
        hint "network access is blocked here, often by a sandbox (pitfall 13); run doctor from a normal terminal" ;;
      *"timed out"*|*"No route to host"*|*"Connection refused"*|*"Connection closed"*)
        hint "the PC is not reachable; check it is on, on this network, and that sshd and its firewall rule are set up (pitfalls 3 and 4)" ;;
      *)
        hint "run 'ssh -v $host' to see where it stops" ;;
    esac
    [[ -n $msg ]] && printf '%s\n' "$msg" | sed 's/^/          /'
    skip "Windows-side checks and MCP round trip (need a working SSH login)"
    finish
  fi
  ok "ssh $who"

  # ------------------------------------------------------ 5-9. Windows side
  # One round trip, cmd.exe syntax. Each part prints a fixed token or a line
  # whose wording does not depend on the Windows display language.
  rmcp=$(printf '%s' "$remote" | grep -oE '[A-Za-z]:\\[^&|<>"]*rhinomcp\.exe' | head -1)
  rport=$(printf '%s' "$remote" | grep -oE 'RHINO_MCP_PORT=[0-9]+' | head -1)
  rport=${rport#*=}
  rport=${rport:-1999}
  cfg='C:\ProgramData\ssh\sshd_config'
  probe="(if exist \"${rmcp:-C:\\nonexistent}\" (echo RMCP=yes) else (echo RMCP=no))"
  probe+=" & (whoami /groups | findstr /C:S-1-5-32-544 >nul && echo ADMIN=yes || echo ADMIN=no)"
  probe+=" & (reg query HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System /v EnableLUA 2>nul | findstr /I EnableLUA || echo LUA=unknown)"
  probe+=" & (type $cfg >nul 2>&1 && (findstr /B /N /I \"ClientAliveInterval Match\" $cfg & echo CFG=read) || echo CFG=unreadable)"
  probe+=" & (netstat -ano -p TCP | findstr LISTENING | findstr /C:\":$rport \" || echo LISTEN=none)"
  out=$("${doctor_ssh[@]}" "$probe" 2>/dev/null | LC_ALL=C tr -d '\r')

  # 5. rhinomcp.exe
  if [[ -z $rmcp ]]; then
    skip "rhinomcp.exe on Windows (no rhinomcp.exe path in Codex's remote command)"
  elif [[ $out == *RMCP=yes* ]]; then
    ok "rhinomcp.exe found at $rmcp"
  else
    fail "rhinomcp.exe not found at $rmcp"
    hint "install it as ${user:-that user} with 'uv tool install rhinomcp==<pinned version>', or fix the path in Codex's config"
  fi

  # 6. account type
  if [[ $out == *ADMIN=yes* ]]; then
    warn "${user:-the SSH user} is an administrator; the SSH key gives a fully elevated shell"
    hint "a dedicated standard account for SSH is recommended (docs/remote-setup.md, Security)"
  elif [[ $out == *ADMIN=no* ]]; then
    ok "${user:-the SSH user} is a standard account"
  else
    skip "account type (no answer from Windows)"
  fi

  # 7. UAC
  lua=$(printf '%s\n' "$out" | grep -i 'EnableLUA' | grep -oE '0x[0-9a-fA-F]+' | head -1)
  if [[ $lua == 0x0 ]]; then
    warn "UAC is off: code run through Rhino has full administrator rights"
    hint "the SSH account limits the shell only; see docs/remote-setup.md, Security"
  elif [[ -n $lua ]]; then
    ok "UAC is on"
  else
    skip "UAC (could not read EnableLUA)"
  fi

  # 8. sshd ClientAliveInterval, read from the file (sshd -T needs an
  # administrator), so "set" means written, not proven in effect.
  if [[ $out == *CFG=unreadable* || $out != *CFG=read* ]]; then
    skip "sshd ClientAliveInterval (cannot read $cfg as ${user:-this user})"
  else
    cai_line=$(printf '%s\n' "$out" | grep -iE '^[0-9]+:ClientAliveInterval' | head -1)
    match_line=$(printf '%s\n' "$out" | grep -iE '^[0-9]+:Match' | head -1)
    cai_no=${cai_line%%:*}
    cai_val=$(printf '%s' "${cai_line#*:}" | awk '{print $2}')
    match_no=${match_line%%:*}
    if [[ -z $cai_line || $cai_val == 0 ]]; then
      warn "sshd ClientAliveInterval is not set: a dropped network leaves rhinomcp running on Windows (pitfall 16)"
      hint "set ClientAliveInterval 15 and ClientAliveCountMax 3 in $cfg (docs/remote-setup.md, Option 1)"
    elif [[ -n $match_no ]] && ((cai_no > match_no)); then
      warn "sshd ClientAliveInterval sits after a Match line, so it applies to that Match block only"
      hint "move it above the first Match line in $cfg"
    else
      ok "sshd ClientAliveInterval $cai_val (in the file; restart sshd if it was just changed)"
    fi
  fi

  # 9. Rhino listener
  if [[ $out == *LISTEN=none* ]]; then
    fail "nothing listens on Windows port $rport"
    hint "run 'mcpstart' in Rhino on the PC"
  elif printf '%s\n' "$out" | grep -q "127\.0\.0\.1:$rport "; then
    ok "Rhino listens on Windows 127.0.0.1:$rport"
  elif printf '%s\n' "$out" | grep -q "LISTENING"; then
    warn "port $rport on Windows listens beyond loopback"
  else
    skip "Rhino listener (no answer from Windows)"
  fi
fi

# ----------------------------------------------------- 10. MCP round trip
# The exact command Codex runs, with its env, speaking newline-delimited
# JSON-RPC. bash 3.2 has no coproc, so two FIFOs carry stdin and stdout.
mcp_round_trip() {
  local dir pid line want got="" polluted=0 code verdict start t0=$SECONDS

  dir=$(mktemp -d "${TMPDIR:-/tmp}/rhino-doctor.XXXXXX")
  mkfifo "$dir/in" "$dir/out"
  env ${envs[@]+"${envs[@]}"} "$command" ${args[@]+"${args[@]}"} \
      <"$dir/in" >"$dir/out" 2>"$dir/err" &
  pid=$!
  exec 3>"$dir/in" 4<"$dir/out"

  rt_fail() {
    exec 3>&- 4<&-
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "MCP round trip: $1"
    [[ -n ${2:-} ]] && hint "$2"
    local err
    err=$(grep -v '^\*\*' "$dir/err" | readable | tail -3)
    [[ -n $err ]] && printf '%s\n' "$err" | sed 's/^/          /'
    rm -rf "$dir"
  }

  # Reads until a line carries "id":<want>; leaves it in $got.
  await() {
    want=$1
    start=$SECONDS
    while ((SECONDS - start < TIMEOUT)); do
      if ! IFS= read -r -t "$TIMEOUT" -u 4 line; then
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"
          code=$?
          return 2
        fi
        return 1
      fi
      line=${line%$'\r'}
      case $line in
        '{'*) ;;
        *) polluted=$((polluted + 1)); continue ;;
      esac
      case $line in
        *'"id":'"$want"[,}]*|*'"id": '"$want"[,}]*) got=$line; return 0 ;;
      esac
    done
    return 1
  }

  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rhino-doctor","version":"0"}}}' >&3
  await 1
  case $? in
    1) rt_fail "no answer to initialize within ${TIMEOUT}s"; return ;;
    2) rt_fail "the server exited during startup (exit $code)" \
         "check the command in Codex's config; the error output is below"; return ;;
  esac
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"'"$TOOL"'","arguments":{}}}' >&3
  await 2
  case $? in
    1) rt_fail "no answer to $TOOL within ${TIMEOUT}s"; return ;;
    2) rt_fail "the server exited during $TOOL (exit $code)"; return ;;
  esac

  exec 3>&-
  wait "$pid"
  exec 4<&-
  rm -rf "$dir"

  # rhinomcp reports an unreachable Rhino as ordinary text with isError false,
  # so match the message before trusting the flag.
  case $got in
    *'Could not connect to Rhino'*)
      fail "MCP round trip: the server runs but cannot reach Rhino"
      hint "run 'mcpstart' in Rhino on the PC" ;;
    *'"error"'*)
      fail "MCP round trip: protocol error: ${got:0:160}" ;;
    *'"isError":true'*)
      fail "MCP round trip: $TOOL returned an error: ${got:0:160}" ;;
    *'"result"'*)
      if ((polluted)); then
        fail "MCP round trip works, but stdout carried $polluted non-JSON line(s)"
        hint "something on Windows prints before the server starts (a login script, a banner); a real client may choke on it"
      else
        ok "MCP round trip: $TOOL answered in $((SECONDS - t0))s"
      fi ;;
    *)
      fail "MCP round trip: unexpected reply: ${got:0:160}" ;;
  esac
}

mcp_round_trip
finish
