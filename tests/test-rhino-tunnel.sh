#!/usr/bin/env bash
# Verification harness for rhino-tunnel.sh.
#
# Drives the real tunnel script against a fake ssh(1) written into a temp dir
# and prepended to PATH, so it never touches ~/.ssh/config, the real rhino-pc,
# or port 1999. The fake binds the -L port like a real established forward, so
# the script's port probes see a lifelike tunnel.
#
# Scenarios:
#   T1  SIGTERM to the script alone while the forward is up -> ssh killed+reaped
#   T2  SIGTERM during the backoff sleep                   -> prompt exit
#   T3  group-wide SIGHUP = the terminal C-c / window-close mechanism
#   T4  ssh dying on its own: real drop / never connected / flapping
#       -> reset vs backoff classification + reconnect
#   T5  ssh refused the network ("Operation not permitted", as in a sandbox)
#       -> stops with exit 3 instead of retrying forever (pitfall 13)
#
# Usage: tests/test-rhino-tunnel.sh
set -uo pipefail

TUNNEL="$(cd "$(dirname "$0")/.." && pwd)/scripts/rhino-tunnel.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rhino-tunnel-test.XXXXXX")"
FAKE_BIN="$WORK/bin"
# The tunnel's TMPDIR, to check it leaves no temp file behind.
TUN_TMP="$WORK/tmp"
mkdir -p "$FAKE_BIN" "$TUN_TMP"
: > "$WORK/empty.toml"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 2; }

cat > "$FAKE_BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh(1): accepts "-N -L bind:port:host:port -o k=v HOST".
# FAKE_MODE: hold (default) | quick-fail | sandbox | die-<N>s
[[ -n ${FAKE_ARGS_FILE:-} ]] && printf '%s\n' "$@" >> "$FAKE_ARGS_FILE"
spec=""
while (($#)); do
  case $1 in
    -L) spec=$2; shift 2 ;;
    -N) shift ;;
    -o) shift 2 ;;
    *)  shift ;;
  esac
done
port=${spec#*:}; port=${port%%:*}
mode=${FAKE_MODE:-hold}
case $mode in
  quick-fail) sleep 0.3; exit 255 ;;
  sandbox)    echo "ssh: connect to host win-fake port 22: Operation not permitted" >&2; exit 255 ;;
  die-*s)    life=${mode#die-}; life=${life%s} ;;
  *)         life=0 ;;
esac
exec python3 - "$port" "$life" <<'PY'
import socket, sys, time
port, life = int(sys.argv[1]), float(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
print(f"[fake-ssh] forward bound on 127.0.0.1:{port}, life={life or 'forever'}", flush=True)
try:
    if life > 0:
        time.sleep(life)
    else:
        while True:
            c, _ = s.accept()
            c.close()
finally:
    print("[fake-ssh] exiting", flush=True)
PY
FAKE
chmod +x "$FAKE_BIN/ssh"

pass=0; fail=0; TIMEOUT=15; TPID=
ok()  { echo "  ok   : $1"; pass=$((pass+1)); }
bad() { echo "  FAIL : $1"; fail=$((fail+1)); }
assert_contains() { # file substring desc
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"
  else bad "$3 (missing [$2] in $1)"; fi
}

port_is_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
port_is_free()     { ! port_is_listening "$1"; }
tmp_is_empty()     { [[ -z $(ls -A "$TUN_TMP") ]]; }

wait_until() { # predicate... -- true within TIMEOUT seconds
  local i=0
  while (( i < TIMEOUT * 5 )); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.2; i=$((i+1))
  done
  return 1
}

gone_within() { # pid seconds -- process exits within the window
  local pid=$1 secs=$2 i=0
  while (( i < secs * 5 )); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2; i=$((i+1))
  done
  return 1
}

# spawn <log> -- starts the tunnel with globals MODE PORT BASE MAX; sets TPID.
spawn() {
  local log=$1
  env PATH="$FAKE_BIN:$PATH" \
      FAKE_MODE="$MODE" FAKE_ARGS_FILE="$WORK/args.log" \
      HOST=win-fake LOCAL_PORT="$PORT" REMOTE_PORT=1999 TMPDIR="$TUN_TMP" \
      BASE_DELAY="$BASE" MAX_DELAY="$MAX" CODEX_CONFIG="$WORK/empty.toml" \
      "$TUNNEL" >"$log" 2>&1 &
  TPID=$!
  wait_until grep -qF "ctrl-c to stop" "$log" || {
    bad "tunnel failed to start (see $log)"
    return 1
  }
}

stop_tunnel() {
  [[ -n $TPID ]] || return 0
  kill -TERM "$TPID" 2>/dev/null
  local i=0
  while kill -0 "$TPID" 2>/dev/null && (( i < 20 )); do sleep 0.2; i=$((i+1)); done
  kill -9 "$TPID" 2>/dev/null
  wait "$TPID" 2>/dev/null
  TPID=
}
trap 'stop_tunnel; rm -rf "$WORK"' EXIT

t1_term_while_up() {
  echo "T1: SIGTERM to the script alone while the forward is up"
  MODE=hold PORT=29931 BASE=1 MAX=4
  local log="$WORK/t1.log" child
  spawn "$log" || return
  wait_until port_is_listening "$PORT" || { bad "forward never bound (T1)"; stop_tunnel; return; }
  child=$(pgrep -P "$TPID" | head -1)
  [[ -n $child ]] || { bad "no ssh child found (T1)"; stop_tunnel; return; }

  kill -TERM "$TPID"
  if gone_within "$TPID" 2; then ok "script exits promptly on SIGTERM while ssh is up (T1)"
  else bad "script alive 2s after SIGTERM with ssh up (T1)"; stop_tunnel; return; fi
  if kill -0 "$child" 2>/dev/null; then bad "ssh child left running (T1)"
  else ok "ssh child killed and reaped (T1)"; fi
  port_is_free "$PORT" && ok "local port released (T1)" || bad "local port still held (T1)"
  assert_contains "$log" "[tunnel] stopped." "stop message printed (T1)"
  tmp_is_empty && ok "temp file removed (T1)" || bad "temp file left in $TUN_TMP (T1)"
  stop_tunnel
}

t2_term_during_backoff() {
  echo "T2: SIGTERM while backing off between retries"
  MODE=quick-fail PORT=29932 BASE=30 MAX=60
  local log="$WORK/t2.log" child
  spawn "$log" || return
  wait_until grep -qF "retrying in" "$log" || { bad "no retry line (T2)"; stop_tunnel; return; }
  assert_contains "$log" "never connected" "failed connect classified as never-connected (T2)"
  assert_contains "$log" "retrying in 60s" "backoff doubled to the cap (T2)"

  child=$(pgrep -P "$TPID" | head -1)
  [[ -n $child ]] || { bad "no backoff child found (T2)"; stop_tunnel; return; }
  kill -TERM "$TPID"
  if gone_within "$TPID" 2; then ok "prompt exit from mid-backoff SIGTERM (T2)"
  else bad "script alive 2s after SIGTERM during backoff (T2)"; stop_tunnel; return; fi
  if kill -0 "$child" 2>/dev/null; then bad "backoff sleep left behind (T2)"
  else ok "backoff sleep killed and reaped (T2)"; fi
  port_is_free "$PORT" && ok "port untouched by mid-backoff stop (T2)" || bad "port held (T2)"
  stop_tunnel
}

t3_sigint_to_group() {
  echo "T3: signal to the whole process group (the terminal C-c / window-close mechanism)"
  MODE=hold PORT=29933 BASE=1 MAX=4
  local log="$WORK/t3.log" child
  # Terminal C-c is SIGINT to every member of the foreground process group;
  # closing the window is SIGHUP to the same set. The script traps INT, TERM
  # and HUP with one handler, and TERM is already proven end-to-end by T1/T2,
  # so the group HUP below exercises the one thing those do not: kernel group
  # delivery reaching script and ssh child at once. SIGINT itself is
  # undeliverable from the environment this harness runs in (verified: direct
  # and group INT are silently swallowed while TERM/HUP arrive), so after any
  # change to the trap line, give real Ctrl-C one manual keystroke in a
  # terminal. Own session => own process group, so `kill -HUP -TPID` is a
  # faithful group delivery.
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    env PATH="$FAKE_BIN:$PATH" \
        FAKE_MODE="$MODE" FAKE_ARGS_FILE="$WORK/args.log" \
        HOST=win-fake LOCAL_PORT="$PORT" REMOTE_PORT=1999 TMPDIR="$TUN_TMP" \
        BASE_DELAY="$BASE" MAX_DELAY="$MAX" CODEX_CONFIG="$WORK/empty.toml" \
        "$TUNNEL" >"$log" 2>&1 &
  TPID=$!
  wait_until grep -qF "ctrl-c to stop" "$log" || { bad "tunnel failed to start (T3)"; stop_tunnel; return; }
  wait_until port_is_listening "$PORT" || { bad "forward never bound (T3)"; stop_tunnel; return; }
  child=$(pgrep -P "$TPID" | head -1)
  [[ -n $child ]] || { bad "no ssh child found (T3)"; stop_tunnel; return; }
  if [[ $(ps -o pgid= -p "$child" | tr -d ' ') == "$TPID" ]]; then
    ok "ssh child shares the script's process group (T3)"
  else bad "ssh child not in the script's process group (T3)"; fi

  kill -HUP -"$TPID"
  if gone_within "$TPID" 3; then ok "clean exit on group SIGHUP (T3)"
  else bad "script alive 3s after group SIGHUP (T3)"; stop_tunnel; return; fi
  if kill -0 "$child" 2>/dev/null; then bad "ssh child left running (T3)"
  else ok "ssh child gone after group signal (T3)"; fi
  port_is_free "$PORT" && ok "local port released (T3)" || bad "local port still held (T3)"
  assert_contains "$log" "[tunnel] stopped." "stop message printed (T3)"
  tmp_is_empty && ok "temp file removed (T3)" || bad "temp file left in $TUN_TMP (T3)"
  stop_tunnel
}

t4_reconnect() {
  echo "T4a: forward up then dropping after 6s, repeatedly"
  MODE=die-6s PORT=29934 BASE=1 MAX=8
  local log="$WORK/t4a.log" drops
  spawn "$log" || return
  sleep 15
  stop_tunnel
  assert_contains "$log" "connection dropped after" "real drop reported (T4a)"
  assert_contains "$log" "retrying in 1s" "backoff resets after a real drop (T4a)"
  drops=$(grep -cF "connection dropped" "$log" || true)
  if [[ ${drops:-0} -ge 2 ]]; then ok "reconnected after each drop ($drops drops seen, T4a)"
  else bad "expected >=2 drops in 15s, saw ${drops:-0} (T4a)"; fi
  port_is_free "$PORT" && ok "port released after stop (T4a)" || bad "port held (T4a)"

  echo "T4b: connect failures back off, capped at MAX_DELAY"
  MODE=quick-fail PORT=29935 BASE=1 MAX=4
  local log="$WORK/t4b.log" capped
  spawn "$log" || return
  sleep 15
  stop_tunnel
  assert_contains "$log" "never connected" "failure classified as never-connected (T4b)"
  assert_contains "$log" "retrying in 2s" "backoff doubles (T4b)"
  capped=$(grep -cF "retrying in 4s" "$log" || true)
  if [[ ${capped:-0} -ge 2 ]]; then ok "backoff capped at MAX_DELAY (T4b)"
  else bad "expected >=2 capped retries, saw ${capped:-0} (T4b)"; fi

  echo "T4c: forward binds but dies fast (flapping link)"
  MODE=die-1s PORT=29936 BASE=1 MAX=8
  local log="$WORK/t4c.log"
  spawn "$log" || return
  sleep 6
  stop_tunnel
  assert_contains "$log" "unstable" "short-lived session flagged unstable (T4c)"
  assert_contains "$log" "retrying in 2s" "flapping backs off instead of resetting (T4c)"
}

t5_sandbox() {
  echo "T5: ssh may not use the network (sandbox) -> stop, no retry"
  MODE=sandbox PORT=29937 BASE=1 MAX=4
  local log="$WORK/t5.log" code
  spawn "$log" || return
  if gone_within "$TPID" 3; then ok "script stops by itself (T5)"
  else bad "script still retrying 3s after a sandbox failure (T5)"; stop_tunnel; return; fi
  wait "$TPID"; code=$?
  TPID=
  [[ $code -eq 3 ]] && ok "exit code 3 (T5)" || bad "exit code $code, expected 3 (T5)"
  assert_contains "$log" "port 22: Operation not permitted" "ssh's own error still shown (T5)"
  assert_contains "$log" "retrying cannot help" "reason printed (T5)"
  if grep -qF "retrying in" "$log"; then bad "a retry was scheduled (T5)"
  else ok "no retry scheduled (T5)"; fi
  tmp_is_empty && ok "temp file removed (T5)" || bad "temp file left in $TUN_TMP (T5)"
  if pgrep -f "tee -a $TUN_TMP" >/dev/null; then bad "tee left running (T5)"
  else ok "no tee left running (T5)"; fi
}

t1_term_while_up
t2_term_during_backoff
t3_sigint_to_group
t4_reconnect
t5_sandbox

# Pinned across all six spawns (args.log accumulates one argument per line):
# the daemon's ssh must never be able to prompt -- a password or host-key
# question reads from /dev/tty, which this script's terminal window answers.
assert_contains "$WORK/args.log" "BatchMode=yes" "ssh always invoked with BatchMode=yes"
# Each spawn runs ssh's stderr through tee; none may outlive its tunnel.
sleep 0.5
if pgrep -f "tee -a $TUN_TMP" >/dev/null; then bad "a tee outlived its tunnel"
else ok "no tee outlived its tunnel"; fi

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))