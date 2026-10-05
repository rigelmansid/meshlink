#!/usr/bin/env bash
# First-time setup on the Mac for Option 1: an SSH key, a Host entry in
# ~/.ssh/config, the command to run on the PC, the PC's host key checked by
# eye, and one test login.
#
# Safe to run again. Nothing existing is overwritten: an existing key is
# reused, an existing Host entry is left alone (differences are listed), and a
# known_hosts entry that disagrees with the PC stops the run.
#
# Usage:
#   scripts/setup.sh --address <pc-address> --user <windows-user>
#   scripts/setup.sh --host rhino-agent --address <pc-address> --user rhino-agent
#
#   --host NAME          Host alias in ~/.ssh/config        (default: rhino-pc)
#   --address ADDR       the PC's address, for HostName      (asked if needed)
#   --user NAME          the Windows account to log in as    (asked if needed)
#   --key PATH           private key   (default: ~/.ssh/id_ed25519_rhino)
#   --fingerprint FP     expected host key, SHA256:...; skips the question
#
# Questions are read from stdin.
set -uo pipefail

PROG=setup
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/sshcfg.sh
source "$HERE/lib/sshcfg.sh"

HOST_ALIAS=rhino-pc
ADDRESS=""
WIN_USER=""
KEY="$HOME/.ssh/id_ed25519_rhino"
KEY_SET=no
EXPECT_FP=""

while (($#)); do
  case $1 in
    --host) HOST_ALIAS=${2:-}; shift 2 ;;
    --address) ADDRESS=${2:-}; shift 2 ;;
    --user) WIN_USER=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; KEY_SET=yes; shift 2 ;;
    --fingerprint) EXPECT_FP=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
KNOWN="$SSH_DIR/known_hosts"
STAMP=$(date +%Y%m%d-%H%M%S)

# On a rerun the Host entry already names its key. Use that one unless --key
# says otherwise, or the Windows command would carry the wrong public key.
if [[ $KEY_SET == no ]] && has_alias; then
  entry_key=$(resolved identityfile)
  [[ -n $entry_key ]] && KEY=${entry_key/#\~/$HOME}
fi

# ---------------------------------------------------------------- 1. key
ensure_key || finish

# ---------------------------------------------------------- 2. ssh config
if has_alias; then
  have_addr=$(resolved hostname)
  have_user=$(resolved user)
  ok "Host $HOST_ALIAS already in $(tilde "$CONFIG"); leaving it as it is"
  [[ -n $ADDRESS && $ADDRESS != "$have_addr" ]] &&
    warn "it points to $have_addr, not $ADDRESS"
  [[ -n $WIN_USER && $WIN_USER != "$have_user" ]] &&
    warn "it logs in as $have_user, not $WIN_USER"
  ((warns)) && hint "edit $(tilde "$CONFIG") by hand, or pick another name with --host"
  ADDRESS=$have_addr
  WIN_USER=$have_user
else
  while [[ -z $ADDRESS ]]; do
    ask "PC address (IP or name, as shown by prepare-windows.ps1): " || { fail "no address given"; finish; }
    ADDRESS=$REPLY
  done
  while [[ -z $WIN_USER ]]; do
    ask "Windows account to log in as (a dedicated standard account is recommended): " ||
      { fail "no account given"; finish; }
    WIN_USER=$REPLY
  done
  add_host_entry
fi

set_kh_name

windows_step() {
  echo
  echo "On the PC, open Windows PowerShell as administrator and run prepare-windows.ps1."
  echo "Copy it over first; on this Mac it is $HERE/prepare-windows.ps1"
  echo
  echo "  powershell -NoProfile -ExecutionPolicy Bypass -File .\\prepare-windows.ps1 -User $WIN_USER -PublicKey \"$PUBKEY\""
  echo
  echo "Its report ends with the PC's host key (\"host key SHA256:...\"); keep it at hand."
  ask "Press Enter when it has finished: " || true
  echo
}

# -------------------------------------------- 3. host key, 4. test login
# Once the key is trusted and accepted, a rerun has nothing left to do.
known_entry
if [[ -n $KNOWN_ENTRY ]] && [[ $(login) == *setup-ok* ]]; then
  ok "host key for $ADDRESS already trusted"
  ok "ssh $HOST_ALIAS logs in as $WIN_USER"
  hint "next: $CMD_CLIENT --host $HOST_ALIAS, then $CMD_DOCTOR"
  finish
fi

windows_step

scan_host_key || finish

if [[ -n $KNOWN_ENTRY ]]; then
  check_known_host_key || finish
else
  echo "The PC at $ADDRESS presents this host key:"
  echo
  echo "  $FP (ED25519)"
  echo
  if [[ -n $EXPECT_FP ]]; then
    if [[ $EXPECT_FP != "$FP" ]]; then
      fail "host key $FP is not the expected $EXPECT_FP"
      hint "do not connect; check the address and the fingerprint printed by prepare-windows.ps1"
      finish
    fi
  else
    ask "Is it the same as the host key prepare-windows.ps1 printed? (yes/no): " || REPLY=""
    if [[ $REPLY != yes ]]; then
      fail "host key not confirmed; nothing was added to known_hosts"
      hint "check the address, and compare with the 'host key' line of prepare-windows.ps1"
      finish
    fi
  fi
  trust_host_key
fi

out=$(login)
if [[ $out == *setup-ok* ]]; then
  ok "ssh $HOST_ALIAS logs in as $WIN_USER"
  hint "next: $CMD_CLIENT --host $HOST_ALIAS, then $CMD_DOCTOR"
else
  fail "ssh $HOST_ALIAS does not log in yet"
  printf '%s\n' "$out" | grep -v '^\*\*' | readable | tail -3 | sed 's/^/          /'
  hint "check prepare-windows.ps1 ran for $WIN_USER with this key, then run this again"
fi
finish
