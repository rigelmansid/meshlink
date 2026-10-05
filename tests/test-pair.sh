#!/usr/bin/env bash
# Verification harness for the pairing protocol (docs/pairing.md).
#
# V: scripts/lib/pairing.sh must reproduce tests/pairing-vectors.txt, which was
# generated with Python independently of the bash code.
#
# P: scripts/pair.sh against a fake Rhino plug-in, a Python client written
# into a temp dir that speaks the four steps over 127.0.0.1. HOME is a temp
# dir and PATH puts fake dns-sd, ssh and ssh-keyscan first, so nothing is
# announced on the network and the real ~/.ssh is never touched; nc is the
# real /usr/bin/nc, since serving the steps with it is what is being tested.
# Everything runs under /bin/bash, the macOS system bash 3.2.
#
# Scenarios:
#   V1  each vector: commitment and pairing code      -> as in the file
#   V2  nonces                                        -> 32 hex digits, not repeated
#   P1  PC pairs, Mac answers yes                     -> Host entry, known_hosts, exit 0
#   P2  a stray connection comes first                -> ignored, pairing completes
#   P3  host key does not match the commitment        -> FAIL, no code shown, nothing written
#   P4  Mac answers no                                -> PC told "no", nothing written
#   P5  PC declines                                   -> FAIL, nothing written
#   P6  PC fails, message with an escape sequence     -> FAIL, message shown without it
#   P7  sshd at the address has another host key      -> FAIL, nothing written
#   P8  addresses: invalid, option-like, silent, PC   -> only valid ones scanned, PC's used
#   P9  account name with spaces                      -> FAIL, nothing written
#   P10 no PC within the timeout                      -> FAIL, nothing left running
#   P11 Host alias already exists                     -> FAIL before announcing
#   P12 port already in use                           -> FAIL before announcing
#   P13 SIGTERM while waiting / at the question       -> stops, nothing left running
#   P14 known_hosts has another key for the address   -> FAIL, no Host entry
#   P15 login still refused after pairing             -> FAIL with a hint, entry kept
#
# Ports 29951-29952 must be free.
#
# Usage: tests/test-pair.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/pairing.sh"
PAIR="$ROOT/scripts/pair.sh"
VECTORS="$ROOT/tests/pairing-vectors.txt"
PORT=29951
BUSY_PORT=29952

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 2; }
for p in $PORT $BUSY_PORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $p is in use; free it first"
    exit 2
  fi
done

pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL : $1"; fail=$((fail + 1)); }
same() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (got [$1], want [$2])"; }

# lib FUNCTION ARGS... -- runs one function under /bin/bash with a clean env.
lib() {
  env -i PATH=/usr/bin:/bin /bin/bash -c 'source "$0"; "$@"' "$LIB" "$@"
}

# A literal \r in a vector field stands for a CR byte.
unescape() { printf '%s' "${1//\\r/$'\r'}"; }

echo "V1 vectors"
n=0
while IFS='|' read -r name macpub hostkey nonce_m nonce_w commit sas; do
  [[ -z $name || $name == \#* ]] && continue
  n=$((n + 1))
  macpub=$(unescape "$macpub")
  hostkey=$(unescape "$hostkey")
  same "$(lib pair_commit "$hostkey" "$nonce_w")" "$commit" "$name: commitment"
  same "$(lib pair_sas "$macpub" "$hostkey" "$nonce_m" "$nonce_w")" "$sas" "$name: pairing code"
done <"$VECTORS"
((n >= 4)) && ok "read $n vectors" || bad "read only $n vectors"

echo "V2 nonces"
a=$(lib pair_nonce)
b=$(lib pair_nonce)
[[ $a =~ ^[0-9a-f]{32}$ ]] && ok "nonce is 32 lowercase hex digits" || bad "nonce format [$a]"
[[ $a != "$b" ]] && ok "two nonces differ" || bad "nonce repeated [$a]"

# ------------------------------------------------------------------ fakes
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meshlink-pair-test.XXXXXX")"
BIN="$WORK/bin"
mkdir -p "$BIN"
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
RHINO_PID=""
HOLD_PID=""
cleanup() {
  [[ -n $RHINO_PID ]] && kill "$RHINO_PID" 2>/dev/null
  [[ -n $HOLD_PID ]] && kill "$HOLD_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/otherkey"

cat >"$BIN/dns-sd" <<'FAKE'
#!/usr/bin/env bash
# fake dns-sd -R: logs its arguments, reports the registration, waits to be killed.
printf '%s\n' "$*" >>"$FAKE_DNSSD_LOG"
echo "Registering Service $2.$3.$4 port $5"
echo "00:00:00.000  Got a reply for service $2.$3.$4.: Name now registered and active"
trap 'exit 0' TERM
while :; do sleep 0.2; done
FAKE

cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh: -G goes to the real ssh; the login test answers per FAKE_LOGIN.
for a in "$@"; do [[ $a == -G ]] && exec /usr/bin/ssh "$@"; done
if [[ ${FAKE_LOGIN:-ok} == denied ]]; then
  echo "agent@pc: Permission denied (publickey,keyboard-interactive)." >&2
  exit 255
fi
[[ ${!#} == "echo setup-ok" ]] && { printf 'setup-ok\r\n'; exit 0; }
echo "fake ssh: unexpected: ${!#}" >&2
exit 1
FAKE

cat >"$BIN/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
# fake ssh-keyscan: logs the address asked for; answers only for addresses in
# FAKE_SCAN_ADDRS, with FAKE_HOSTKEY.
addr=${!#}
printf '%s\n' "$addr" >>"$FAKE_SCAN_LOG"
case " $FAKE_SCAN_ADDRS " in *" $addr "*) ;; *) exit 0 ;; esac
echo "# $addr:22 SSH-2.0-OpenSSH_for_Windows_fake"
echo "$addr $(cut -d' ' -f1,2 "$FAKE_HOSTKEY")"
FAKE
chmod +x "$BIN/dns-sd" "$BIN/ssh" "$BIN/ssh-keyscan"

cat >"$WORK/fake-rhino.py" <<'FAKE'
# Fake Rhino plug-in: the Windows side of docs/pairing.md, over 127.0.0.1.
# Writes what it saw (NAME, SAS, CONFIRM, DONE) to --out.
import argparse, hashlib, secrets, socket, sys, time

p = argparse.ArgumentParser()
p.add_argument("--port", type=int, required=True)
p.add_argument("--hostkey", required=True)
p.add_argument("--addr", action="append", default=[])
p.add_argument("--user", default="agent")
p.add_argument("--result", default="ok")
p.add_argument("--message", action="append", default=[])
p.add_argument("--bad-commit", action="store_true")
p.add_argument("--stray-first", action="store_true")
p.add_argument("--patience", type=float, default=30)
p.add_argument("--out", required=True)
a = p.parse_args()

def key(k): return " ".join(k.replace("\r", "").split()[:2])
def sha(s): return hashlib.sha256(s.encode()).hexdigest()
def log(line):
    with open(a.out, "a") as f: f.write(line + "\n")

def talk(payload):
    # The Mac listens only once it is ready for a step: retry refused connects.
    end = time.time() + a.patience
    while True:
        try:
            s = socket.create_connection(("127.0.0.1", a.port), timeout=5)
            break
        except OSError:
            if time.time() > end:
                log("GAVE-UP"); sys.exit(1)
            time.sleep(0.1)
    s.sendall(payload)
    s.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        b = s.recv(4096)
        if not b: break
        data += b
    s.close()
    return data.decode()

def step(n, lines):
    while True:
        text = talk(("MESHLINK-PAIR 1\nSTEP %d\n" % n + "".join(l + "\n" for l in lines)).encode())
        reply = {}
        for line in text.splitlines()[1:]:
            k, _, v = line.partition(" ")
            reply.setdefault(k, v)
        if reply.get("STEP") == str(n):
            return reply
        time.sleep(0.2)

hostkey = key(open(a.hostkey).read())
if a.stray_first:
    talk(b"GET / HTTP/1.0\r\n\r\n")
nonce_w = secrets.token_hex(16)
commit = sha("meshlink-pair-v1 commit\n%s\n%s\n" % (hostkey, nonce_w))
if a.bad_commit:
    commit = sha("something else")
r1 = step(1, ["COMMIT " + commit])
log("NAME " + r1["NAME"])
step(2, ["HOSTKEY " + hostkey, "NONCE " + nonce_w] + ["ADDR " + x for x in a.addr])
h = sha("meshlink-pair-v1 sas\n%s\n%s\n%s\n%s\n" % (key(r1["MACPUB"]), hostkey, r1["NONCE"], nonce_w))
n = "%06d" % (int(h[:8], 16) % 1000000)
log("SAS %s %s" % (n[:3], n[3:]))
r3 = step(3, [])
log("CONFIRM " + r3.get("CONFIRM", ""))
if r3.get("CONFIRM") != "yes":
    sys.exit(0)
lines = ["RESULT " + a.result] + (["USER " + a.user] if a.user else [])
step(4, lines + ["MESSAGE " + m for m in a.message])
log("DONE")
FAKE

# ---------------------------------------------------------------- harness
has()     { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
hasnt()   { grep -qF -- "$2" "$1" && bad "$3 (unexpected [$2] in $1)" || ok "$3"; }
exit_is() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (exit $1, want $2)"; }

fresh_home() {
  H="$WORK/home-$1"
  rm -rf "$H"
  mkdir -p "$H"
}

# rhino NAME ARGS... -- starts the fake plug-in; RHINO_ADDRS lists its addresses.
rhino() {
  local name=$1 x
  shift
  RHINO_OUT="$WORK/$name.rhino"
  : >"$RHINO_OUT"
  local addr_args=()
  for x in ${RHINO_ADDRS:-127.0.0.1}; do addr_args+=("--addr=$x"); done
  python3 "$WORK/fake-rhino.py" --port "$PORT" --hostkey "$WORK/hostkey.pub" \
      --out "$RHINO_OUT" "${addr_args[@]}" "$@" &
  RHINO_PID=$!
}
stop_rhino() {
  [[ -n $RHINO_PID ]] && { kill "$RHINO_PID" 2>/dev/null; wait "$RHINO_PID" 2>/dev/null; }
  RHINO_PID=""
}

# pair_env NAME ARGS... -- execs pair.sh with a clean environment. exec, so
# that a backgrounded call's $! is pair.sh itself (P13 signals it).
pair_env() {
  exec env -i HOME="$H" PATH="$BIN:$SYS_PATH" TMPDIR="$WORK" \
      FAKE_DNSSD_LOG="$WORK/$1.dnssd" FAKE_HOSTKEY="${FAKE_HOSTKEY:-$WORK/hostkey.pub}" \
      FAKE_SCAN_ADDRS="${FAKE_SCAN_ADDRS:-127.0.0.1}" FAKE_SCAN_LOG="$WORK/$1.scan" \
      FAKE_LOGIN="${FAKE_LOGIN:-ok}" \
      /bin/bash "$PAIR" --port "$PORT" --timeout "${TIMEOUT:-20}" --name test-mac "${@:2}"
}

# pair_run NAME INPUT ARGS... -- runs pair.sh with INPUT on stdin; sets out, rc.
pair_run() {
  local name=$1 input=$2
  shift 2
  out="$WORK/$name.log"
  printf '%b' "$input" | pair_env "$name" "$@" >"$out" 2>&1
  rc=$?
}

no_leftovers() {
  pgrep -f "$BIN/dns-sd" >/dev/null && bad "$1: dns-sd left running" || ok "$1: no dns-sd left running"
  # Anchored: an unanchored pattern also matches any shell whose command line
  # merely mentions it.
  pgrep -f "^nc -l $PORT\$" >/dev/null && bad "$1: nc left running" || ok "$1: no nc left running"
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && bad "$1: port $PORT still listening" ||
    ok "$1: port $PORT free"
  ls -d "$WORK"/meshlink-pair.* >/dev/null 2>&1 && bad "$1: temp dir left" || ok "$1: temp dir removed"
}

nothing_written() {
  [[ ! -e $H/.ssh/config ]] && ok "$1: no ssh config written" || bad "$1: ssh config written"
  [[ ! -s $H/.ssh/known_hosts ]] && ok "$1: known_hosts untouched" || bad "$1: known_hosts written"
}

HOSTKEY_B64=$(cut -d' ' -f2 "$WORK/hostkey.pub")

# ----------------------------------------------------------- pair cases
echo "P1 PC pairs, Mac answers yes"
fresh_home p1
rhino p1
pair_run p1 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 0 "P1 exit 0"
sas=$(sed -n 's/^SAS //p' "$RHINO_OUT")
[[ -n $sas ]] && has "$out" "    $sas" "P1 Mac shows the code the PC computed ($sas)" || bad "P1 PC computed no code"
has "$RHINO_OUT" "CONFIRM yes" "P1 PC told yes"
has "$RHINO_OUT" "NAME test-mac" "P1 PC sees the Mac's name"
has "$RHINO_OUT" "DONE" "P1 PC finished all four steps"
has "$WORK/p1.dnssd" "-R test-mac _meshlink-pair._tcp local $PORT v=1" "P1 announced with the port and version"
has "$H/.ssh/config" "# Added by scripts/pair.sh on" "P1 entry marked as added by pair.sh"
has "$H/.ssh/config" "Host rhino-pc" "P1 Host entry"
has "$H/.ssh/config" "HostName 127.0.0.1" "P1 HostName is the PC's address"
has "$H/.ssh/config" "User agent" "P1 User is the account the PC reported"
has "$H/.ssh/config" "IdentityFile ~/.ssh/id_ed25519_rhino" "P1 IdentityFile"
[[ $(stat -f %Lp "$H/.ssh/config") == 600 ]] && ok "P1 config mode 600" || bad "P1 config mode"
has "$H/.ssh/known_hosts" "127.0.0.1 ssh-ed25519 $HOSTKEY_B64" "P1 known_hosts has the paired host key"
has "$out" "ssh rhino-pc logs in as agent" "P1 test login"
has "$out" "next: scripts/client-codex.sh --host rhino-pc" "P1 next step"
no_leftovers P1

echo "P2 a stray connection comes first"
fresh_home p2
rhino p2 --stray-first
pair_run p2 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 0 "P2 exit 0"
has "$out" "ignored a connection that was not step 1" "P2 stray ignored"
has "$H/.ssh/config" "Host rhino-pc" "P2 Host entry"
no_leftovers P2

echo "P3 host key does not match the commitment"
fresh_home p3
rhino p3 --bad-commit --patience 3
pair_run p3 'yes\n'
stop_rhino
exit_is "$rc" 1 "P3 exit 1"
has "$out" "does not match what it committed to" "P3 FAIL"
hasnt "$out" "Pairing code" "P3 no code shown"
nothing_written P3
no_leftovers P3

echo "P4 Mac answers no"
fresh_home p4
rhino p4
pair_run p4 'no\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P4 exit 1"
has "$RHINO_OUT" "CONFIRM no" "P4 PC told no"
hasnt "$RHINO_OUT" "DONE" "P4 PC did not go on to step 4"
has "$out" "pairing code not confirmed; nothing was written" "P4 FAIL"
nothing_written P4
no_leftovers P4

echo "P5 PC declines"
fresh_home p5
rhino p5 --result declined --user ""
pair_run p5 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P5 exit 1"
has "$out" "declined on the PC; nothing was written" "P5 FAIL"
nothing_written P5

echo "P6 PC fails, message with an escape sequence"
fresh_home p6
rhino p6 --result fail --user "" --message $'sshd is not\e[31m installed'
pair_run p6 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P6 exit 1"
has "$out" "could not install this Mac's key" "P6 FAIL"
has "$out" "PC: sshd is not[31m installed" "P6 message shown"
grep -q $'\e' "$out" && bad "P6 escape character reached the terminal" || ok "P6 escape character removed"
nothing_written P6

echo "P7 sshd at the address has another host key"
fresh_home p7
rhino p7
FAKE_HOSTKEY="$WORK/otherkey.pub" pair_run p7 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P7 exit 1"
has "$out" "no address of the PC presents the paired host key" "P7 FAIL"
has "$out" "127.0.0.1 (another host key)" "P7 says what it found"
nothing_written P7

echo "P8 addresses: invalid, silent, then the PC"
fresh_home p8
RHINO_ADDRS="999.1.1.1 -oProxyCommand=evil 192.0.2.1 127.0.0.1" rhino p8
pair_run p8 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 0 "P8 exit 0"
has "$H/.ssh/config" "HostName 127.0.0.1" "P8 the answering address is used"
[[ $(paste -sd' ' - <"$WORK/p8.scan") == "192.0.2.1 127.0.0.1" ]] &&
  ok "P8 only valid addresses scanned, in order" ||
  bad "P8 scanned: $(paste -sd' ' - <"$WORK/p8.scan")"

echo "P9 account name with spaces"
fresh_home p9
rhino p9 --user "agent ProxyCommand evil"
pair_run p9 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P9 exit 1"
has "$out" "account name this Mac cannot use" "P9 FAIL"
nothing_written P9

echo "P10 no PC within the timeout"
fresh_home p10
TIMEOUT=2 pair_run p10 ''
exit_is "$rc" 1 "P10 exit 1"
has "$out" "no PC started pairing within 2s" "P10 FAIL"
nothing_written P10
no_leftovers P10

echo "P11 Host alias already exists"
fresh_home p11
mkdir -p "$H/.ssh"
printf 'Host rhino-pc\n    HostName 192.0.2.9\n' >"$H/.ssh/config"
cp "$H/.ssh/config" "$WORK/p11.before"
pair_run p11 'yes\n'
exit_is "$rc" 1 "P11 exit 1"
has "$out" "Host rhino-pc is already in" "P11 FAIL"
[[ ! -s $WORK/p11.dnssd ]] && ok "P11 nothing announced" || bad "P11 dns-sd was started"
cmp -s "$H/.ssh/config" "$WORK/p11.before" && ok "P11 config unchanged" || bad "P11 config changed"

echo "P12 port already in use"
fresh_home p12
python3 -c 'import socket, time
s = socket.socket(); s.bind(("127.0.0.1", '"$BUSY_PORT"')); s.listen(1); time.sleep(30)' &
HOLD_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lsof -nP -iTCP:$BUSY_PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
pair_run p12 'yes\n' --port "$BUSY_PORT"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""
exit_is "$rc" 1 "P12 exit 1"
has "$out" "port $BUSY_PORT is already in use" "P12 FAIL"
[[ ! -s $WORK/p12.dnssd ]] && ok "P12 nothing announced" || bad "P12 dns-sd was started"

echo "P13 SIGTERM while waiting / at the question"
fresh_home p13
pair_env p13 </dev/null >"$WORK/p13.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.1
done
kill -TERM "$pid"
wait "$pid"
exit_is "$?" 1 "P13 exit 1 on SIGTERM while waiting"
has "$WORK/p13.log" "[FAIL] stopped" "P13 says it stopped"
nothing_written P13
no_leftovers P13
# At the question: stdin is a FIFO that stays open and empty, so read blocks.
fresh_home p13b
mkfifo "$WORK/p13b.in"
exec 7<>"$WORK/p13b.in"
rhino p13b --patience 3
pair_env p13b <"$WORK/p13b.in" >"$WORK/p13b.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  grep -q "same code as in Rhino" "$WORK/p13b.log" 2>/dev/null && break
  sleep 0.1
done
kill -TERM "$pid"
wait "$pid"
exit_is "$?" 1 "P13 exit 1 on SIGTERM at the question"
exec 7>&-
stop_rhino
has "$WORK/p13b.log" "[FAIL] stopped" "P13 says it stopped at the question"
nothing_written P13b
no_leftovers P13b

echo "P14 known_hosts has another key for the address"
fresh_home p14
mkdir -p "$H/.ssh"
echo "127.0.0.1 $(cut -d' ' -f1,2 "$WORK/otherkey.pub")" >"$H/.ssh/known_hosts"
cp "$H/.ssh/known_hosts" "$WORK/p14.before"
rhino p14
pair_run p14 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P14 exit 1"
has "$out" "does not match the one in" "P14 FAIL"
[[ ! -e $H/.ssh/config ]] && ok "P14 no Host entry" || bad "P14 Host entry written"
cmp -s "$H/.ssh/known_hosts" "$WORK/p14.before" && ok "P14 known_hosts unchanged" || bad "P14 known_hosts changed"

echo "P15 login still refused after pairing"
fresh_home p15
rhino p15
FAKE_LOGIN=denied pair_run p15 'yes\n'
wait "$RHINO_PID"; RHINO_PID=""
exit_is "$rc" 1 "P15 exit 1"
has "$out" "ssh rhino-pc does not log in yet" "P15 FAIL"
has "$out" "scripts/setup.sh --host rhino-pc continues by hand" "P15 hint"
has "$H/.ssh/config" "Host rhino-pc" "P15 entry kept"

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
