#!/bin/bash
# Probe an MCP stdio server with one tool call, in plain bash 3.2 (macOS's
# /bin/bash): no coproc, no jq, no Python. Checks whether a future `doctor`
# can test the MCP layer without extra dependencies.
#
# Usage:
#   experiments/mcp_stdio_probe.sh TOOL -- CMD...
#
#   experiments/mcp_stdio_probe.sh get_document_summary -- \
#       ssh -T -o BatchMode=yes rhino-pc 'C:\Users\<user>\.local\bin\rhinomcp.exe'
#
# Sends initialize, then one tools/call with empty arguments, and classifies the
# reply: OK, RHINO NOT LISTENING, TOOL ERROR or PROTOCOL ERROR. Every stdout line
# must be JSON; anything else is reported as pollution. Exit status 0 only for
# OK with clean stdout. TIMEOUT (seconds, default 30) bounds each reply.
#
# Windows error text in stderr is in the PC's code page (GBK on Chinese
# Windows); pipe through `iconv -f GBK -t UTF-8` to read it.
set -u

if [ $# -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: $0 TOOL -- CMD..." >&2
  exit 2
fi
tool=$1
shift 2
TIMEOUT=${TIMEOUT:-30}

# bash 3.2 has no coproc: wire the server's stdin and stdout to two FIFOs.
dir=$(mktemp -d /tmp/mcpprobe.XXXXXX)
mkfifo "$dir/in" "$dir/out"
"$@" <"$dir/in" >"$dir/out" 2>"$dir/err" &
pid=$!
exec 3>"$dir/in" 4<"$dir/out"

polluted=0
got=""

fail() {
  echo "FAIL: $*"
  exec 3>&- 4<&-
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -rf "$dir"
  exit 1
}

# Read lines until one carries "id":<n>; leave it in $got. Non-JSON lines count
# as pollution. Runs in the main shell, not in $(...), so the counter, the exit
# code from `wait` and fail() all reach the caller.
await() {
  local want=$1 line start=$SECONDS
  while [ $((SECONDS - start)) -lt "$TIMEOUT" ]; do
    if ! IFS= read -r -t "$TIMEOUT" -u 4 line; then
      # EOF (server gone) or timeout; give an exiting server a moment to be reaped.
      sleep 1
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
        local code=$?
        # LC_ALL=C: stderr may not be UTF-8 (see header).
        fail "server exited (code $code); stderr: $(LC_ALL=C tr -d '\r' <"$dir/err" | grep -v '^\*\*' | tail -c 300)"
      fi
      fail "no reply to request $want within ${TIMEOUT}s"
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
  fail "no reply to request $want within ${TIMEOUT}s"
}

t0=$SECONDS
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-stdio-probe-sh","version":"0"}}}' >&3
await 1
case $got in
  *'"result"'*) echo "initialize ok ($((SECONDS - t0))s)" ;;
  *) fail "initialize: ${got:0:200}" ;;
esac

printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"'"$tool"'","arguments":{}}}' >&3
await 2

# rhinomcp reports an unreachable Rhino as ordinary text with isError false, so
# match the message before trusting the flag.
case $got in
  *'"error"'*) verdict="PROTOCOL ERROR" ;;
  *'Could not connect to Rhino'*) verdict="RHINO NOT LISTENING" ;;
  *'"isError":true'*) verdict="TOOL ERROR" ;;
  *'"result"'*) verdict="OK" ;;
  *) verdict="UNKNOWN" ;;
esac
echo "tools/call $tool: $verdict ($((SECONDS - t0))s total, ${#got} B)"
echo "  -> ${got:0:160}"

# Closing stdin is how a client ends a stdio session; the server (and ssh
# carrying it) should exit on EOF.
exec 3>&-
wait "$pid"
code=$?
exec 4<&-
echo "server exited, code $code"
rm -rf "$dir"

if [ "$polluted" -gt 0 ]; then
  echo "STDOUT POLLUTION: $polluted non-JSON line(s)"
  exit 1
fi
echo "stdout clean"
[ "$verdict" = OK ]
