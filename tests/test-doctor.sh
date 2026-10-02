#!/usr/bin/env bash
# Verification harness for scripts/doctor.sh.
#
# Runs the real doctor against a fake codex(1) and a fake ssh(1) written into a
# temp dir. PATH is cut down to that dir plus the system directories, so the
# real Codex config, ~/.ssh/config and the real PC are never touched. The fake
# ssh answers doctor's own commands with Windows-style output (CRLF) and runs a
# small fake MCP server for the round trip.
#
# Scenarios:
#   D1  everything healthy (standard account, UAC on)    -> all OK, exit 0
#   D2  codex not installed                               -> FAIL, rest skipped
#   D3  no MCP server named rhino                         -> FAIL
#   D4  key refused / host key unknown / PC unreachable   -> FAIL + matching hint
#   D5  rhinomcp.exe missing on Windows                   -> FAIL
#   D6  Rhino not listening (no mcpstart)                 -> FAIL twice, exit 1
#   D7  admin account + UAC off                           -> two WARN, exit 0
#   D8  ClientAliveInterval unset / inside a Match block  -> WARN
#   D9  ssh arguments without -T and BatchMode=yes        -> two WARN
#   D10 stray line on the server's stdout                 -> FAIL
#   D11 server exits at startup with a GBK error message  -> FAIL, text decoded
#   D12 Option 2 without a tunnel / with one on loopback  -> FAIL / OK
#
# Ports 29941-29942 must be free (D12).
#
# Usage: tests/test-doctor.sh
set -uo pipefail

DOCTOR="$(cd "$(dirname "$0")/.." && pwd)/scripts/doctor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rhino-doctor-test.XXXXXX")"
BIN="$WORK/bin"
NOCODEX="$WORK/nocodex"
mkdir -p "$BIN" "$NOCODEX"
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (D12)"; exit 2; }

# ------------------------------------------------------------------ fakes
cat >"$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
# fake codex: --version, and `mcp get <name> --json` printing $FAKE_JSON.
case "$*" in
  --version) echo "codex-cli 0.0.0-fake" ;;
  "mcp get rhino --json") [[ -f ${FAKE_JSON:-} ]] && cat "$FAKE_JSON" || {
                            echo "Error: No MCP server named 'rhino' found." >&2; exit 1; } ;;
  *) echo "fake codex: unexpected: $*" >&2; exit 1 ;;
esac
FAKE

# The fake MCP server, used both behind the fake ssh (Option 1) and as the
# local command (Option 2). FAKE_MCP: ok | norhino | pollute | exit
cat >"$BIN/fake-rhinomcp" <<'FAKE'
#!/usr/bin/env bash
case ${FAKE_MCP:-ok} in
  exit)
    # "The system cannot find the path specified." in GBK, as cmd prints it
    printf '\317\265\315\263\325\322\262\273\265\275\326\270\266\250\265\304\302\267\276\266\241\243\r\n' >&2
    exit 1 ;;
  pollute) printf 'banner from a login script\r\n' ;;
esac
while IFS= read -r line; do
  case $line in
    *'"id":1,'*)
      printf '%s\r\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"0"}}}' ;;
    *'"id":2,'*)
      if [[ ${FAKE_MCP:-ok} == norhino ]]; then
        printf '%s\r\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Error getting document summary: Could not connect to Rhino at 127.0.0.1:1999."}],"isError":false}}'
      else
        printf '%s\r\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"objects\": 0}"}],"isError":false}}'
      fi ;;
  esac
done
FAKE

cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh(1). The remote command is the last argument.
# FAKE_SSH: ok | auth | hostkey | unreachable
# Windows probe: FAKE_RMCP yes|no, FAKE_ADMIN yes|no, FAKE_LUA 1|0,
#                FAKE_CAI set|unset|inmatch, FAKE_LISTEN yes|no
[[ -n ${FAKE_ARGS_FILE:-} ]] && printf '%s\n' "$*" >>"$FAKE_ARGS_FILE"
case ${FAKE_SSH:-ok} in
  auth)        echo "rhino-agent@fake-pc: Permission denied (publickey,keyboard-interactive)." >&2; exit 255 ;;
  hostkey)     echo "Host key verification failed." >&2; exit 255 ;;
  unreachable) echo "ssh: connect to host fake-pc port 22: Operation timed out" >&2; exit 255 ;;
esac
remote=${!#}
case $remote in
  "echo doctor-ok") printf 'doctor-ok\r\n' ;;
  *EnableLUA*)
    {
      echo "RMCP=${FAKE_RMCP:-yes}"
      echo "ADMIN=${FAKE_ADMIN:-no}"
      echo "    EnableLUA    REG_DWORD    0x${FAKE_LUA:-1}"
      case ${FAKE_CAI:-set} in
        set)     echo "66:ClientAliveInterval 15"; echo "87:Match Group administrators"; echo "CFG=read" ;;
        unset)   echo "87:Match Group administrators"; echo "CFG=read" ;;
        inmatch) echo "87:Match Group administrators"; echo "90:ClientAliveInterval 15"; echo "CFG=read" ;;
      esac
      if [[ ${FAKE_LISTEN:-yes} == yes ]]; then
        echo "  TCP    127.0.0.1:1999         0.0.0.0:0              LISTENING       4242"
      else
        echo "LISTEN=none"
      fi
    } | sed 's/$/\r/' ;;
  *rhinomcp.exe*) exec "$(dirname "$0")/fake-rhinomcp" ;;
  *) echo "fake ssh: unexpected remote command: $remote" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BIN/codex" "$BIN/ssh" "$BIN/fake-rhinomcp"
cp "$BIN/ssh" "$NOCODEX/ssh"

# Codex's view of the server, as `codex mcp get --json` prints it.
write_json() { # file command arg...   (args are JSON-escaped already)
  local file=$1 cmd=$2 first=1 a
  shift 2
  {
    printf '{\n  "name": "rhino",\n  "enabled": true,\n  "transport": {\n'
    printf '    "type": "stdio",\n    "command": "%s",\n    "args": [\n' "$cmd"
    for a in "$@"; do
      ((first)) || printf ',\n'
      printf '      "%s"' "$a"
      first=0
    done
    printf '\n    ],\n    "env": {\n      "RHINO_MCP_PORT": "%s"\n    },\n' "${JSON_PORT:-1999}"
    printf '    "env_vars": [],\n    "cwd": null\n  },\n  "startup_timeout_sec": 60.0\n}\n'
  } >"$file"
}
REMOTE='set RHINO_MCP_TIMEOUT=30&& C:\\Users\\agent\\.local\\bin\\rhinomcp.exe'
write_json "$WORK/opt1.json" ssh -T -o BatchMode=yes -l agent fake-pc "$REMOTE"
write_json "$WORK/bare.json" ssh fake-pc "$REMOTE"
JSON_PORT=29941 write_json "$WORK/opt2-free.json" "$BIN/fake-rhinomcp"
JSON_PORT=29942 write_json "$WORK/opt2-up.json" "$BIN/fake-rhinomcp"

# ---------------------------------------------------------------- harness
pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL : $1"; fail=$((fail + 1)); }
has()    { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
hasnt()  { grep -qF -- "$2" "$1" && bad "$3 (unexpected [$2] in $1)" || ok "$3"; }
exit_is() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (exit $1, want $2)"; }

# run <name> [VAR=value...] -- runs doctor with the opt1 config unless FAKE_JSON
# is given; sets $out (log file) and $rc.
run() {
  local name=$1
  shift
  out="$WORK/$name.log"
  env -i HOME="$WORK" PATH="$BIN:$SYS_PATH" TMPDIR="$WORK" TIMEOUT=10 \
      FAKE_JSON="$WORK/opt1.json" FAKE_ARGS_FILE="$WORK/$name.args" "$@" \
      /bin/bash "$DOCTOR" >"$out" 2>&1
  rc=$?
}

cleanup() {
  [[ -n ${LPID:-} ]] && kill "$LPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------ cases
echo "D1 healthy"
run d1
exit_is "$rc" 0 "exit 0"
has "$out" "[ OK ] 'rhino' runs the server on Windows over SSH" "Option 1 detected"
has "$out" "[ OK ] ssh agent@fake-pc" "ssh login reported with user and alias"
has "$out" "[ OK ] rhinomcp.exe found at C:\\Users\\agent\\.local\\bin\\rhinomcp.exe" "remote path unescaped"
has "$out" "[ OK ] agent is a standard account" "account type"
has "$out" "[ OK ] UAC is on" "UAC"
has "$out" "[ OK ] sshd ClientAliveInterval 15" "ClientAliveInterval"
has "$out" "[ OK ] Rhino listens on Windows 127.0.0.1:1999" "listener"
has "$out" "[ OK ] MCP round trip: get_document_summary answered" "round trip"
hasnt "$out" "[WARN]" "no warnings"
if grep -vq "BatchMode=yes" "$WORK/d1.args"; then
  bad "every ssh call carries BatchMode=yes"
else
  ok "every ssh call carries BatchMode=yes ($(wc -l <"$WORK/d1.args" | tr -d ' ') calls)"
fi

echo "D2 codex not installed"
out="$WORK/d2.log"
env -i HOME="$WORK" PATH="$NOCODEX:$SYS_PATH" /bin/bash "$DOCTOR" >"$out" 2>&1
rc=$?
exit_is "$rc" 1 "exit 1"
has "$out" "[FAIL] codex not found in PATH" "codex missing reported"
has "$out" "[SKIP] everything else" "rest skipped"

echo "D3 no rhino server in Codex"
run d3 FAKE_JSON="$WORK/none.json"
exit_is "$rc" 1 "exit 1"
has "$out" "[FAIL] Codex has no MCP server named 'rhino'" "missing server reported"

echo "D4 ssh failures"
run d4a FAKE_SSH=auth
exit_is "$rc" 1 "auth: exit 1"
has "$out" "the key was refused" "auth: hint"
has "$out" "[SKIP] Windows-side checks and MCP round trip" "auth: rest skipped"
run d4b FAKE_SSH=hostkey
has "$out" "host key is unknown or changed" "hostkey: hint"
run d4c FAKE_SSH=unreachable
has "$out" "the PC is not reachable" "unreachable: hint"

echo "D5 rhinomcp.exe missing"
run d5 FAKE_RMCP=no
exit_is "$rc" 1 "exit 1"
has "$out" "[FAIL] rhinomcp.exe not found at" "missing exe reported"

echo "D6 Rhino not listening"
run d6 FAKE_LISTEN=no FAKE_MCP=norhino
exit_is "$rc" 1 "exit 1"
has "$out" "[FAIL] nothing listens on Windows port 1999" "listener check fails"
has "$out" "[FAIL] MCP round trip: the server runs but cannot reach Rhino" "round trip names the cause"
has "$out" "run 'mcpstart' in Rhino" "mcpstart hint"

echo "D7 admin account, UAC off"
run d7 FAKE_ADMIN=yes FAKE_LUA=0
exit_is "$rc" 0 "warnings alone keep exit 0"
has "$out" "[WARN] agent is an administrator" "admin warned"
has "$out" "[WARN] UAC is off" "UAC warned"

echo "D8 ClientAliveInterval"
run d8a FAKE_CAI=unset
has "$out" "[WARN] sshd ClientAliveInterval is not set" "unset warned"
run d8b FAKE_CAI=inmatch
has "$out" "[WARN] sshd ClientAliveInterval sits after a Match line" "inside Match warned"

echo "D9 ssh arguments without -T and BatchMode"
run d9 FAKE_JSON="$WORK/bare.json"
has "$out" "[WARN] Codex's ssh arguments lack -T" "-T warned"
has "$out" "[WARN] Codex's ssh arguments lack -o BatchMode=yes" "BatchMode warned"
has "$out" "[ OK ] ssh fake-pc" "login without -l shows the alias only"
# Codex's own arguments lack BatchMode here, so this proves doctor adds it.
own=$(grep -E 'doctor-ok|EnableLUA' "$WORK/d9.args")
if [[ -n $own ]] && ! printf '%s\n' "$own" | grep -vq "BatchMode=yes"; then
  ok "doctor's own ssh calls add BatchMode=yes"
else
  bad "doctor's own ssh calls add BatchMode=yes"
fi

echo "D10 stdout pollution"
run d10 FAKE_MCP=pollute
exit_is "$rc" 1 "exit 1"
has "$out" "stdout carried 1 non-JSON line(s)" "pollution reported"

echo "D11 server exits at startup"
run d11 FAKE_MCP=exit
exit_is "$rc" 1 "exit 1"
has "$out" "the server exited during startup (exit 1)" "early exit reported"
has "$out" "系统找不到指定的路径" "GBK error text decoded"

echo "D12 Option 2"
run d12a FAKE_JSON="$WORK/opt2-free.json"
exit_is "$rc" 1 "no tunnel: exit 1"
has "$out" "(Option 2, port forward)" "Option 2 detected"
has "$out" "[FAIL] nothing listens on local port 29941" "missing tunnel reported"
python3 -c '
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 29942)); s.listen(1); time.sleep(30)' &
LPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lsof -nP -iTCP:29942 -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
run d12b FAKE_JSON="$WORK/opt2-up.json"
exit_is "$rc" 0 "tunnel up: exit 0"
has "$out" "[ OK ] tunnel listens on 127.0.0.1:29942" "loopback tunnel accepted"
has "$out" "[SKIP] Windows-side checks (Option 2" "Windows checks skipped"
has "$out" "[ OK ] MCP round trip" "local round trip"
kill "$LPID" 2>/dev/null
wait "$LPID" 2>/dev/null
LPID=

echo
echo "passed: $pass  failed: $fail"
leftover=$(ls -d "$WORK"/rhino-doctor.* 2>/dev/null)
[[ -z $leftover ]] || { echo "leftover temp dirs: $leftover"; exit 1; }
((fail == 0))
