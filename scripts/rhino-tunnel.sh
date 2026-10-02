#!/usr/bin/env bash
# Keeps a local port forward open to the Rhino MCP bridge on the Windows box.
# Mac 127.0.0.1:1999  ->  Windows 127.0.0.1:1999  (where Rhino's `mcpstart` listens)
#
# Host, user, key and keepalives all come from the `rhino-pc` entry in
# ~/.ssh/config, so this script never restates them. Change the machine there,
# not here.
#
# Three ports are involved and only two of them move together:
#
#   LOCAL_PORT   what rhinomcp on this Mac dials       -- change if 1999 is taken
#   RHINO_MCP_PORT in ~/.codex/config.toml             -- MUST equal LOCAL_PORT
#   REMOTE_PORT  where Rhino's mcpstart listens        -- fixed by Rhino, leave it
#
# Moving LOCAL_PORT without RHINO_MCP_PORT gives a tunnel that starts cleanly
# and fails every request, so the mismatch is checked for below.
#
# Usage:  scripts/rhino-tunnel.sh                    # leave it running in its own window
#         HOST=other-pc scripts/rhino-tunnel.sh      # a different ~/.ssh/config entry
#         LOCAL_PORT=2999 scripts/rhino-tunnel.sh    # plus the same edit in codex config
set -uo pipefail

HOST="${HOST:-rhino-pc}"
LOCAL_PORT="${LOCAL_PORT:-1999}"
REMOTE_PORT="${REMOTE_PORT:-1999}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
BASE_DELAY="${BASE_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-60}"

# Earlier revisions took a single PORT that set both ends at once, which quietly
# pointed the far end at a port Rhino does not listen on. Fail loudly instead of
# ignoring it.
if [[ -n ${PORT:-} ]]; then
  echo "[tunnel] PORT is no longer used — it used to move both ends at once."
  echo "[tunnel] use LOCAL_PORT (and match RHINO_MCP_PORT in codex config)."
  exit 2
fi

# Probe by port, never by process name: `-L` has several equivalent spellings
# and matching on the command line gives false negatives.
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[tunnel] local port $LOCAL_PORT is already taken:"
  lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN
  echo "[tunnel] a tunnel may already be up — kill it, or see LOCAL_PORT above"
  exit 1
fi

# Best effort: the client dials whatever codex config says, so a silent
# disagreement here is the whole failure mode described at the top.
if [[ -r $CODEX_CONFIG ]]; then
  configured=$(grep -oE 'RHINO_MCP_PORT[[:space:]]*=[[:space:]]*"?[0-9]+' "$CODEX_CONFIG" \
               | grep -oE '[0-9]+$' | head -1)
  if [[ -n $configured && $configured != "$LOCAL_PORT" ]]; then
    echo "[tunnel] WARNING: $CODEX_CONFIG has RHINO_MCP_PORT=$configured,"
    echo "[tunnel]          but this tunnel listens on $LOCAL_PORT."
    echo "[tunnel]          The tunnel will look fine and every request will fail."
  fi
fi

# --------------------------------------------------------------- signal path
# Both children the loop creates (the ssh forward and the backoff sleep) run in
# the background with their PID in child_pid. That is not for job control: bash
# defers a trapped signal until the foreground command finishes, so ssh in the
# foreground would swallow a SIGTERM sent to this script alone -- the trap would
# sit unexecuted until ssh died on its own, leaving an orphan holding LOCAL_PORT
# (which the port-in-use check above would then blame on "a tunnel may already
# be up"). `wait` is the one wait primitive a trapped signal interrupts, so every
# blocking point below waits on a tracked child, and cleanup kills and reaps it.
#
# SIGHUP joins INT and TERM in the same trap for a reason of its own: closing
# the terminal window this script runs in delivers SIGHUP, and without the
# trap bash itself would die while the ssh child -- which may or may not have
# gotten the signal, depending on where the terminal sent it -- is left
# orphaned with LOCAL_PORT still held.
child_pid=

cleanup() {
  trap - INT TERM HUP
  if [[ -n $child_pid ]]; then
    kill "$child_pid" 2>/dev/null
    wait "$child_pid" 2>/dev/null
  fi
  echo
  echo "[tunnel] stopped."
  exit 0
}
trap cleanup INT TERM HUP

echo "[tunnel] 127.0.0.1:$LOCAL_PORT  ->  $HOST:$REMOTE_PORT   (ctrl-c to stop)"

delay=$BASE_DELAY
while true; do
  started=$SECONDS

  # Both ends of the forward are spelled out on purpose.
  #
  # Local 127.0.0.1: with the bind address omitted, ssh binds according to
  # GatewayPorts -- so a `GatewayPorts yes` anywhere in ssh_config would put the
  # *unauthenticated* Rhino bridge on every interface of this Mac, silently
  # undoing the whole reason for tunnelling. An explicit bind address overrides
  # that setting.
  #
  # Remote 127.0.0.1: the Rhino listener is IPv4-only, so resolving `localhost`
  # to ::1 on the Windows side would break the forward in a way that looks like
  # a live port that refuses every connection.
  #
  # ExitOnForwardFailure: without it ssh holds the session open even when the
  # forward failed, so this loop reports a healthy tunnel while nothing is
  # actually listening locally. Note it only validates the local bind -- the
  # far end is dialled per connection, so a wrong REMOTE_PORT still starts clean.
  #
  # BatchMode: this is a daemon and must never prompt. Password and
  # host-key-confirm prompts read from /dev/tty rather than stdin, so bash
  # redirecting a background job's stdin from /dev/null does not stop them --
  # and this script deliberately runs in the user's terminal window, where such
  # a prompt (broken authorized_keys on the far end, a regenerated host key)
  # would freeze the whole loop on a question nobody can see being asked.
  # BatchMode turns every prompt into an immediate failure, which the bind
  # probe below then classifies and backs off from. Confirming a new machine's
  # fingerprint is a manual install step (`ssh rhino-pc` once), not this
  # daemon's job.
  ssh -N -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" \
      -o ExitOnForwardFailure=yes -o BatchMode=yes "$HOST" &
  child_pid=$!

  # ssh only sets the local end of a forward up after connecting and
  # authenticating, so "LOCAL_PORT is listening" means the session really came
  # up. This distinguishes a dead far end from a live session even when a failed
  # connect is slow: ConnectTimeout (10 in ~/.ssh/config) makes every refused
  # attempt run ~10s, which a plain "ran less than 5s" test misreads as a
  # healthy session that was up a while -- resetting the backoff every attempt.
  bound=no
  while [[ $bound == no ]] && kill -0 "$child_pid" 2>/dev/null; do
    if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      bound=yes
    else
      sleep 0.5
    fi
  done

  wait "$child_pid"
  code=$?
  child_pid=

  ran=$(( SECONDS - started ))

  # A session that bound and stayed up a while was a real drop worth retrying
  # promptly; one that never bound, or died within seconds of binding, means
  # the far end is down or the link is flapping, so back off.
  if [[ $bound == yes && $ran -ge 5 ]]; then
    delay=$BASE_DELAY
    reason="connection dropped after ${ran}s"
  else
    delay=$(( delay * 2 ))
    (( delay > MAX_DELAY )) && delay=$MAX_DELAY
    if [[ $bound == yes ]]; then
      reason="connection dropped after ${ran}s (unstable)"
    else
      reason="never connected"
    fi
  fi

  echo "[tunnel] $reason (exit $code) — retrying in ${delay}s"

  # Backgrounded for the same reason as ssh: a foreground sleep would hold the
  # trap off for its whole duration, so a SIGTERM during a 60s backoff would
  # take up to a minute to land.
  sleep "$delay" &
  child_pid=$!
  wait "$child_pid"
  child_pid=
done