#!/usr/bin/env bash
# Verification harness for scripts/setup.sh and scripts/client-codex.sh.
#
# HOME points at a temp dir, and PATH puts a fake ssh, ssh-keyscan and codex
# first, so the real ~/.ssh, Codex config and PC are never touched. ssh -G is
# passed to the real ssh (setup.sh always names the config file with -F), and
# the real ssh-keygen makes keys and fingerprints, since both are what is
# being tested.
#
# Scenarios:
#   S1  fresh Mac: key, config, Windows command, fingerprint, login    -> exit 0
#   S2  run again                                -> nothing changes, no wait
#   S3  alias exists with another account        -> WARN, config untouched
#   S4  config with Include and "Host *"         -> entry after Include, before Host *
#   S5  --fingerprint does not match             -> FAIL, known_hosts untouched
#   S6  known_hosts has another key for the PC   -> FAIL
#   S7  fingerprint asked: "yes" / "no"          -> trusted / FAIL
#   C1  no Codex entry                           -> codex mcp add with the exact args
#   C2  identical entry                          -> no add
#   C3  different entry, answer "no"             -> lists lost settings, nothing changes
#   C4  different entry, --yes                   -> backup, add
#   C5  path with a space; rhinomcp.exe missing  -> quoted; FAIL
#
# Usage: tests/test-setup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/scripts/setup.sh"
CLIENT="$ROOT/scripts/client-codex.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rhino-setup-test.XXXXXX")"
BIN="$WORK/bin"
mkdir -p "$BIN"
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
trap 'rm -rf "$WORK"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/otherkey"
FP=$(ssh-keygen -lf "$WORK/hostkey.pub" | awk '{print $2}')

# ------------------------------------------------------------------ fakes
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh: -G goes to the real ssh; otherwise answers by remote command.
# FAKE_LOGIN ok|denied, FAKE_PROFILE, FAKE_RMCP yes|no
for a in "$@"; do [[ $a == -G ]] && exec /usr/bin/ssh "$@"; done
[[ -n ${FAKE_ARGS_FILE:-} ]] && printf '%s\n' "$*" >>"$FAKE_ARGS_FILE"
if [[ ${FAKE_LOGIN:-ok} == denied ]]; then
  echo "agent@pc: Permission denied (publickey,keyboard-interactive)." >&2
  exit 255
fi
remote=${!#}
case $remote in
  "echo setup-ok") printf 'setup-ok\r\n' ;;
  *PROFILE=*) printf 'PROFILE=%s\r\n' "${FAKE_PROFILE:-C:\\Users\\agent}" ;;
  *"if exist"*) printf 'RMCP=%s\r\n' "${FAKE_RMCP:-yes}" ;;
  *) echo "fake ssh: unexpected: $remote" >&2; exit 1 ;;
esac
FAKE

cat >"$BIN/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
# fake ssh-keyscan: prints $FAKE_HOSTKEY for the last argument.
[[ ${FAKE_SCAN:-ok} == fail ]] && exit 1
echo "# ${!#}:22 SSH-2.0-OpenSSH_for_Windows_fake"
echo "${!#} $(cut -d' ' -f1,2 "$FAKE_HOSTKEY")"
FAKE

cat >"$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
# fake codex: `mcp get NAME --json` prints $CODEX_HOME/NAME.json; `mcp add NAME
# -- CMD ARGS...` logs the call and rewrites that file the way Codex would.
state=${CODEX_HOME:?}
case $1 in
  --version) echo "codex-cli 0.0.0-fake" ;;
  mcp)
    case $2 in
      get) [[ -f $state/$3.json ]] && cat "$state/$3.json" || exit 1 ;;
      add)
        name=$3; shift 4; cmd=$1; shift
        printf '%s\n' "$name|$cmd|$*" >>"$state/add.log"
        esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
        {
          printf '{\n  "name": "%s",\n  "transport": {\n    "type": "stdio",\n' "$name"
          printf '    "command": "%s",\n    "args": [\n' "$(esc "$cmd")"
          first=1
          for a in "$@"; do
            ((first)) || printf ',\n'
            printf '      "%s"' "$(esc "$a")"; first=0
          done
          printf '\n    ],\n    "env": {},\n    "env_vars": [],\n    "cwd": null\n  },\n'
          printf '  "startup_timeout_sec": null\n}\n'
        } >"$state/$name.json" ;;
    esac ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$BIN/ssh" "$BIN/ssh-keyscan" "$BIN/codex"

# ---------------------------------------------------------------- harness
pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL : $1"; fail=$((fail + 1)); }
has()     { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
hasnt()   { grep -qF -- "$2" "$1" && bad "$3 (unexpected [$2] in $1)" || ok "$3"; }
exit_is() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (exit $1, want $2)"; }

fresh_home() {
  H="$WORK/home-$1"
  rm -rf "$H"
  mkdir -p "$H/.codex"
}

# run NAME INPUT SCRIPT ARGS... (env: H, plus FAKE_* passed through)
run() {
  local name=$1 input=$2 script=$3
  shift 3
  out="$WORK/$name.log"
  printf '%b' "$input" | env -i HOME="$H" CODEX_HOME="$H/.codex" PATH="$BIN:$SYS_PATH" \
      TMPDIR="$WORK" FAKE_HOSTKEY="${FAKE_HOSTKEY:-$WORK/hostkey.pub}" \
      FAKE_LOGIN="${FAKE_LOGIN:-ok}" FAKE_RMCP="${FAKE_RMCP:-yes}" \
      FAKE_PROFILE="${FAKE_PROFILE:-C:\\Users\\agent}" \
      /bin/bash "$script" "$@" >"$out" 2>&1
  rc=$?
}

# ------------------------------------------------------------ setup cases
echo "S1 fresh Mac"
fresh_home s1
run s1 '\n' "$SETUP" --address 10.0.0.9 --user agent --fingerprint "$FP"
exit_is "$rc" 0 "exit 0"
[[ -f $H/.ssh/id_ed25519_rhino && -f $H/.ssh/id_ed25519_rhino.pub ]] && ok "key pair created" || bad "key pair created"
[[ $(stat -f %Lp "$H/.ssh") == 700 && $(stat -f %Lp "$H/.ssh/config") == 600 ]] &&
  ok "~/.ssh is 700 and config 600" || bad "~/.ssh is 700 and config 600"
has "$H/.ssh/config" "Host rhino-pc" "config has the Host entry"
has "$H/.ssh/config" "IdentityFile ~/.ssh/id_ed25519_rhino" "IdentityFile written with ~"
has "$out" "-User agent -PublicKey \"ssh-ed25519 " "Windows command carries the public key"
has "$H/.ssh/known_hosts" "10.0.0.9 ssh-ed25519 " "host key trusted under the address"
has "$out" "[ OK ] ssh rhino-pc logs in as agent" "test login"
[[ $(/usr/bin/ssh -F "$H/.ssh/config" -G rhino-pc | awk '$1=="user"{print $2}') == agent ]] &&
  ok "ssh -G resolves user agent" || bad "ssh -G resolves user agent"

echo "S2 run again"
cp "$H/.ssh/config" "$WORK/s1.config"
run s2 '' "$SETUP" --address 10.0.0.9 --user agent
exit_is "$rc" 0 "exit 0"
cmp -s "$H/.ssh/config" "$WORK/s1.config" && ok "config unchanged" || bad "config unchanged"
hasnt "$out" "prepare-windows.ps1 -User" "no Windows step when already working"
has "$out" "already trusted" "host key recognised"
[[ -z $(ls "$H/.ssh" | grep bak-) ]] && ok "no backup made" || bad "no backup made"

echo "S3 alias exists with another account"
run s3 '' "$SETUP" --address 10.0.0.9 --user other
cmp -s "$H/.ssh/config" "$WORK/s1.config" && ok "config untouched" || bad "config untouched"
has "$out" "[WARN] it logs in as agent, not other" "difference reported"

echo "S4 Include and Host * already there"
fresh_home s4
mkdir -p "$H/.ssh"
printf 'Include extra.conf\n\nHost *\n    User nobody\n' >"$H/.ssh/config"
: >"$H/.ssh/extra.conf"
run s4 '\n' "$SETUP" --address 10.0.0.9 --user agent --fingerprint "$FP"
exit_is "$rc" 0 "exit 0"
order=$(grep -nE '^(Include|Host)' "$H/.ssh/config" | tr '\n' ' ')
[[ $order == "1:Include extra.conf 4:Host rhino-pc 13:Host * " ]] &&
  ok "entry between Include and Host *" || bad "entry between Include and Host * ($order)"
[[ $(/usr/bin/ssh -F "$H/.ssh/config" -G rhino-pc | awk '$1=="user"{print $2}') == agent ]] &&
  ok "Host * does not override the user" || bad "Host * does not override the user"
ls "$H/.ssh" | grep -q '^config.bak-' && ok "backup of the old config" || bad "backup of the old config"

echo "S5 wrong --fingerprint"
fresh_home s5
run s5 '\n' "$SETUP" --address 10.0.0.9 --user agent --fingerprint SHA256:not-this-one
exit_is "$rc" 1 "exit 1"
has "$out" "is not the expected SHA256:not-this-one" "mismatch reported"
[[ ! -s $H/.ssh/known_hosts ]] && ok "known_hosts untouched" || bad "known_hosts untouched"

echo "S6 known_hosts has another key for the PC"
fresh_home s6
mkdir -p "$H/.ssh"
echo "10.0.0.9 $(cut -d' ' -f1,2 "$WORK/otherkey.pub")" >"$H/.ssh/known_hosts"
FAKE_LOGIN=denied run s6 '\n' "$SETUP" --address 10.0.0.9 --user agent
exit_is "$rc" 1 "exit 1"
has "$out" "does not match the one in" "changed host key reported"
has "$out" "ssh-keygen -R" "removal hint"

echo "S7 fingerprint asked"
fresh_home s7
run s7a '\nyes\n' "$SETUP" --address 10.0.0.9 --user agent
exit_is "$rc" 0 "yes: exit 0"
has "$out" "$FP" "fingerprint shown"
has "$H/.ssh/known_hosts" "10.0.0.9 ssh-ed25519" "yes: trusted"
fresh_home s7b
run s7b '\nno\n' "$SETUP" --address 10.0.0.9 --user agent
exit_is "$rc" 1 "no: exit 1"
[[ ! -s $H/.ssh/known_hosts ]] && ok "no: known_hosts untouched" || bad "no: known_hosts untouched"

# ----------------------------------------------------------- client cases
WANT='rhino|ssh|-T -o BatchMode=yes rhino-pc set RHINO_MCP_TIMEOUT=30&& C:\Users\agent\.local\bin\rhinomcp.exe'

echo "C1 no Codex entry"
fresh_home c1
run c1 '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0"
[[ $(cat "$H/.codex/add.log" 2>/dev/null) == "$WANT" ]] && ok "codex mcp add with the exact args" ||
  bad "codex mcp add with the exact args ($(cat "$H/.codex/add.log" 2>/dev/null))"
has "$out" "[DONE] Codex's 'rhino' entry now runs" "read back after writing"

echo "C2 identical entry"
rm -f "$H/.codex/add.log"
run c2 '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0"
[[ ! -f $H/.codex/add.log ]] && ok "no add when identical" || bad "no add when identical"
has "$out" "already runs" "reported as already set"

echo "C3 different entry, answer no"
fresh_home c3
cat >"$H/.codex/rhino.json" <<'JSON'
{
  "name": "rhino",
  "transport": {
    "type": "stdio",
    "command": "/Users/x/.local/bin/rhinomcp",
    "args": [],
    "env": {
      "RHINO_MCP_PORT": "1999"
    },
    "env_vars": [],
    "cwd": null
  },
  "startup_timeout_sec": 60.0
}
JSON
printf '[mcp_servers.rhino]\ncommand = "x"\n\n[mcp_servers.rhino.tools.delete_object]\napproval_mode = "approve"\n' \
  >"$H/.codex/config.toml"
cp "$H/.codex/config.toml" "$WORK/c3.toml"
run c3 'no\n' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0 (declined is not an error)"
has "$out" "- env RHINO_MCP_PORT" "lost env listed"
has "$out" "- startup_timeout_sec = 60.0" "lost timeout listed"
has "$out" "- tools.delete_object settings" "lost approval listed"
has "$out" "comments are dropped" "rewrite of the whole file mentioned"
has "$out" "[INFO] nothing changed" "declined"
[[ ! -f $H/.codex/add.log ]] && ok "no add" || bad "no add"
cmp -s "$H/.codex/config.toml" "$WORK/c3.toml" && ok "config.toml untouched" || bad "config.toml untouched"
[[ -z $(ls "$H/.codex" | grep bak-) ]] && ok "no backup when declined" || bad "no backup when declined"

echo "C4 different entry, --yes"
run c4 '' "$CLIENT" --yes --no-doctor
exit_is "$rc" 0 "exit 0"
ls "$H/.codex" | grep -q '^config.toml.bak-' && ok "backup made" || bad "backup made"
[[ $(cat "$H/.codex/add.log" 2>/dev/null) == "$WANT" ]] && ok "replaced with the exact args" || bad "replaced with the exact args"

echo "C5 path with a space; missing exe"
fresh_home c5
FAKE_PROFILE='C:\Users\John Smith' run c5a '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "space: exit 0"
has "$H/.codex/add.log" 'set RHINO_MCP_TIMEOUT=30&& "C:\Users\John Smith\.local\bin\rhinomcp.exe"' "space: path quoted"
fresh_home c5b
FAKE_RMCP=no run c5b '' "$CLIENT" --no-doctor
exit_is "$rc" 1 "missing: exit 1"
has "$out" "[FAIL] rhinomcp.exe not found at" "missing: reported"
[[ ! -f $H/.codex/add.log ]] && ok "missing: nothing written" || bad "missing: nothing written"

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
