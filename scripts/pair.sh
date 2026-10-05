#!/usr/bin/env bash
# Pairs this Mac with a PC over the local network, in place of setup.sh's
# Windows command and fingerprint check. The meshlink Rhino plug-in on the PC
# (planned for 0.2, not available yet) finds this Mac, both screens show the
# same six-digit code, and once both people confirm, the PC installs this
# Mac's key and this Mac trusts the PC's host key. The SSH link itself is
# unchanged. Protocol: docs/pairing.md.
#
# Nothing is written to ~/.ssh until both sides have confirmed and the PC
# reports the key installed; only the key itself is created first if missing,
# as setup.sh does. The Host alias must not exist yet.
#
# Usage:
#   scripts/pair.sh [--host rhino-pc] [--key PATH] [--port 29950] [--timeout 300]
#
#   --host NAME      Host alias to add to ~/.ssh/config      (default: rhino-pc)
#   --key PATH       private key   (default: ~/.ssh/id_ed25519_rhino)
#   --port N         TCP port this Mac listens on while pairing  (default: 29950)
#   --timeout S      seconds to wait for the PC to start, and later for its
#                    result                                  (default: 300)
#   --name TEXT      how the PC shows this Mac   (default: the computer name)
#
# The pairing code question is read from stdin.
set -uo pipefail

PROG=pair
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/sshcfg.sh
source "$HERE/lib/sshcfg.sh"
# shellcheck source=lib/pairing.sh
source "$HERE/lib/pairing.sh"

HOST_ALIAS=rhino-pc
KEY="$HOME/.ssh/id_ed25519_rhino"
# Not PORT: sshcfg.sh uses that name for the PC's ssh port.
LISTEN_PORT=29950
TIMEOUT=300
NAME=""

while (($#)); do
  case $1 in
    --host) HOST_ALIAS=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --port) LISTEN_PORT=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
if ! [[ $LISTEN_PORT =~ ^[0-9]+$ ]] || ((LISTEN_PORT < 1024 || LISTEN_PORT > 65535)); then
  echo "--port must be a number from 1024 to 65535" >&2
  exit 2
fi
if ! [[ $TIMEOUT =~ ^[0-9]+$ ]] || ((TIMEOUT < 1)); then
  echo "--timeout must be a number of seconds" >&2
  exit 2
fi

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
KNOWN="$SSH_DIR/known_hosts"
STAMP=$(date +%Y%m%d-%H%M%S)

# ------------------------------------------------------------ 1. before
for tool in dns-sd nc lsof shasum ssh-keygen ssh-keyscan; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
((fails)) && finish

if has_alias; then
  fail "Host $HOST_ALIAS is already in $(tilde "$CONFIG"); pairing adds a new entry"
  hint "pair under another name with --host NAME, or keep that entry and use $CMD_SETUP"
  finish
fi
if lsof -nP -iTCP:"$LISTEN_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $LISTEN_PORT is already in use on this Mac"
  hint "pick another one with --port"
  finish
fi
if [[ -z $NAME ]]; then
  NAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
fi
NAME=$(printf '%s' "$NAME" | pair_text)

ensure_key || finish

# --------------------------------------------------------- 2. children
# dns-sd announces this Mac until the PC has made contact; nc serves one
# connection per step. Both run in the background so that a timeout can stop
# them, and cleanup stops whichever is running on every way out: a normal
# finish, a failure, or a signal (INT from the terminal, HUP when it closes).
DNSSD_PID=""
NC_PID=""
TMP=$(mktemp -d "${TMPDIR:-/tmp}/meshlink-pair.XXXXXX") || { fail "could not create a temporary directory"; finish; }

stop_dnssd() {
  if [[ -n $DNSSD_PID ]]; then
    kill "$DNSSD_PID" 2>/dev/null
    wait "$DNSSD_PID" 2>/dev/null
  fi
  DNSSD_PID=""
}
stop_nc() {
  if [[ -n $NC_PID ]]; then
    kill "$NC_PID" 2>/dev/null
    wait "$NC_PID" 2>/dev/null
  fi
  NC_PID=""
}
cleanup() {
  stop_nc
  stop_dnssd
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'trap - INT TERM HUP; echo; fail "stopped"; finish' INT TERM HUP

# serve STEP TIMEOUT KEY... -- answers connections on LISTEN_PORT with
# $TMP/resp until one is the message for STEP with every KEY, which is left
# in $TMP/req. Anything else (a port scan, another PC) is ignored and the
# next connection is served. Returns 1 when TIMEOUT seconds pass first, 2 if
# nc cannot listen.
serve() {
  local step=$1 deadline=$((SECONDS + $2)) rc
  shift 2
  while ((SECONDS < deadline)); do
    # ulimit caps what a peer can make nc write here: 64 KiB.
    (ulimit -f 64; exec nc -l "$LISTEN_PORT") <"$TMP/resp" >"$TMP/req" 2>"$TMP/nc.err" &
    NC_PID=$!
    while kill -0 "$NC_PID" 2>/dev/null && ((SECONDS < deadline)); do
      sleep 0.2
    done
    if kill -0 "$NC_PID" 2>/dev/null; then
      stop_nc
      return 1
    fi
    wait "$NC_PID"
    rc=$?
    NC_PID=""
    pair_is_step "$TMP/req" "$step" "$@" && return 0
    if [[ ! -s $TMP/req && $rc -ne 0 ]]; then
      fail "could not listen on port $LISTEN_PORT: $(head -1 "$TMP/nc.err" | pair_text)"
      return 2
    fi
    info "ignored a connection that was not step $step of this pairing"
  done
  return 1
}

# respond STEP KEY VALUE ... -- writes the reply for STEP to $TMP/resp.
respond() {
  local step=$1
  shift
  {
    printf 'MESHLINK-PAIR %s\nSTEP %s\n' "$PAIR_VERSION" "$step"
    while (($# >= 2)); do
      printf '%s %s\n' "$1" "$2"
      shift 2
    done
  } >"$TMP/resp"
}

# ------------------------------------------- 3. announce, step 1: commit
dns-sd -R "$NAME" _meshlink-pair._tcp local "$LISTEN_PORT" "v=$PAIR_VERSION" >"$TMP/dnssd.log" 2>&1 &
DNSSD_PID=$!
tries=0
until grep -q 'Name now registered and active' "$TMP/dnssd.log" 2>/dev/null; do
  if ! kill -0 "$DNSSD_PID" 2>/dev/null || ((tries >= 50)); then
    fail "could not announce this Mac on the local network (dns-sd)"
    tail -3 "$TMP/dnssd.log" | LC_ALL=C tr -d '\000-\011\013-\037\177' | sed 's/^/          /'
    finish
  fi
  sleep 0.2
  tries=$((tries + 1))
done

NONCE_M=$(pair_nonce)
respond 1 NAME "$NAME" MACPUB "$(pair_key "$PUBKEY")" NONCE "$NONCE_M"
info "this Mac is offering to pair as \"$NAME\" (port $LISTEN_PORT, up to ${TIMEOUT}s)"
hint "on the PC, accept the request from this Mac in Rhino (needs the meshlink plug-in)"
serve 1 "$TIMEOUT" COMMIT
rc=$?
stop_dnssd
if ((rc == 1)); then
  fail "no PC started pairing within ${TIMEOUT}s"
  hint "check that Rhino runs with the meshlink plug-in and both computers are on the same network"
fi
((rc)) && finish
COMMIT=$(pair_get "$TMP/req" COMMIT)
if ! [[ $COMMIT =~ ^[0-9a-f]{64}$ ]]; then
  fail "the PC sent a malformed first message"
  finish
fi
ok "a PC answered; stopped announcing this Mac"

# ------------------------------------------------- 4. step 2: reveal
respond 2
serve 2 30 HOSTKEY NONCE ADDR
rc=$?
if ((rc == 1)); then
  fail "the PC did not continue after the first step"
  hint "nothing was written; pair again"
fi
((rc)) && finish

HOSTKEY=$(pair_key "$(pair_get "$TMP/req" HOSTKEY)")
NONCE_W=$(pair_get "$TMP/req" NONCE)
ADDRS=()
while IFS= read -r a; do
  [[ $a =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || continue
  # 10# keeps a part such as 08 from being read as octal.
  ((10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 &&
    10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255)) && ADDRS+=("$a")
done < <(pair_get_all "$TMP/req" ADDR)

key_re='^ssh-ed25519 [A-Za-z0-9+/]+=*$'
FP=""
[[ $HOSTKEY =~ $key_re ]] && FP=$(printf '%s\n' "$HOSTKEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
if [[ -z $FP || ! $NONCE_W =~ ^[0-9a-f]{32}$ || ${#ADDRS[@]} -eq 0 ]]; then
  fail "the PC sent a malformed second message"
  finish
fi
# The commitment came before this Mac's nonce went out; a match means the PC
# fixed its host key and nonce without knowing it (docs/pairing.md).
if [[ $(pair_commit "$HOSTKEY" "$NONCE_W") != "$COMMIT" ]]; then
  fail "the PC's host key does not match what it committed to"
  hint "something else on the network may be answering; nothing was written"
  finish
fi

# --------------------------------------------- 5. pairing code, step 3
SAS=$(pair_sas "$PUBKEY" "$HOSTKEY" "$NONCE_M" "$NONCE_W")
echo
echo "Pairing code (Rhino on the PC shows a code too):"
echo
echo "    $SAS"
echo
ask "Is it the same code as in Rhino? (yes/no): " || REPLY=""
if [[ $REPLY != yes ]]; then
  # Tell the PC, so it changes nothing; it may already be gone.
  respond 3 CONFIRM no
  serve 3 20
  fail "pairing code not confirmed; nothing was written"
  hint "if the codes differ, something else on the network may be answering; pair again"
  finish
fi
respond 3 CONFIRM yes
serve 3 120
rc=$?
if ((rc == 1)); then
  fail "the PC stopped responding after the pairing code"
  hint "nothing was written on this Mac; pair again"
fi
((rc)) && finish

# ------------------------------------------------- 6. step 4: result
info "waiting for the PC: allow the pairing in Rhino (Windows may also ask for administrator approval)"
respond 4
serve 4 "$TIMEOUT" RESULT
rc=$?
if ((rc == 1)); then
  fail "no result from the PC within ${TIMEOUT}s"
  hint "nothing was written on this Mac; check Rhino on the PC, then pair again"
fi
((rc)) && finish

show_messages() {
  local m
  while IFS= read -r m; do
    [[ -n $m ]] && hint "PC: $(printf '%s' "$m" | pair_text)"
  done < <(pair_get_all "$TMP/req" MESSAGE)
  return 0
}

case $(pair_get "$TMP/req" RESULT) in
  ok) ;;
  declined)
    fail "the pairing was declined on the PC; nothing was written"
    show_messages
    finish ;;
  fail)
    fail "the PC could not install this Mac's key; nothing was written on this Mac"
    show_messages
    finish ;;
  *)
    fail "the PC sent an unknown result"
    finish ;;
esac

# The account goes into ~/.ssh/config, so only plain names are accepted.
WIN_USER=$(pair_get "$TMP/req" USER)
if ! [[ $WIN_USER =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ((${#WIN_USER} > 64)); then
  fail "the PC installed the key for an account name this Mac cannot use: $(printf '%s' "$WIN_USER" | pair_text)"
  hint "only letters, digits, '.', '_' and '-' are supported here; for other names use $CMD_SETUP"
  finish
fi
done_ "the PC installed this Mac's key for account $WIN_USER"
show_messages

# ------------------------------------------- 7. address and host key
# The PC lists the address it reached this Mac from first. Use the first
# address whose sshd presents the paired host key: that also proves the
# address really is that PC.
ADDRESS=""
tried=()
for a in "${ADDRS[@]}"; do
  ADDRESS=$a
  set_kh_name
  SCAN=$(ssh-keyscan -T 5 -p "$PORT" -t ed25519 "$a" 2>/dev/null | grep -v '^#' | head -1)
  if [[ -n $SCAN && $(pair_key "$(printf '%s\n' "$SCAN" | cut -d' ' -f2-)") == "$HOSTKEY" ]]; then
    break
  fi
  if [[ -n $SCAN ]]; then
    tried+=("$a (another host key)")
  else
    tried+=("$a (no answer)")
  fi
  ADDRESS=""
done
if [[ -z $ADDRESS ]]; then
  fail "no address of the PC presents the paired host key"
  hint "tried: ${tried[*]}"
  hint "check that sshd runs on the PC; nothing was written on this Mac"
  finish
fi
ok "the PC at $ADDRESS presents the paired host key ($FP)"

known_entry
if [[ -n $KNOWN_ENTRY ]]; then
  check_known_host_key || finish
else
  trust_host_key
fi

add_host_entry

# ----------------------------------------------------- 8. test login
out=$(login)
if [[ $out == *setup-ok* ]]; then
  ok "ssh $HOST_ALIAS logs in as $WIN_USER"
  hint "next: $CMD_CLIENT --host $HOST_ALIAS, then $CMD_DOCTOR"
else
  fail "ssh $HOST_ALIAS does not log in yet"
  printf '%s\n' "$out" | grep -v '^\*\*' | readable | tail -3 | sed 's/^/          /'
  hint "the PC reported the key installed for $WIN_USER; $CMD_SETUP --host $HOST_ALIAS continues by hand from here"
fi
finish
