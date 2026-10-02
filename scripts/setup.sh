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

# Show paths under $HOME with ~, as ssh_config itself would.
tilde() { case $1 in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# ssh -G resolves what ssh will really use for an alias. -F pins the file:
# ssh reads ~/.ssh/config from the password database, not from $HOME.
resolved() { # key
  ssh -F "$CONFIG" -G "$HOST_ALIAS" 2>/dev/null | awk -v k="$1" '$1 == k {print $2; exit}'
}

has_alias() {
  [[ -f $CONFIG ]] &&
    grep -qiE "^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?$HOST_ALIAS([[:space:]]|\$)" "$CONFIG"
}

# On a rerun the Host entry already names its key. Use that one unless --key
# says otherwise, or the Windows command would carry the wrong public key.
if [[ $KEY_SET == no ]] && has_alias; then
  entry_key=$(resolved identityfile)
  [[ -n $entry_key ]] && KEY=${entry_key/#\~/$HOME}
fi

# ---------------------------------------------------------------- 1. key
if [[ ! -d $SSH_DIR ]]; then
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
fi
if [[ -f $KEY ]]; then
  ok "key $(tilde "$KEY") already exists, reusing it"
else
  # A fixed comment: ssh-keygen's default (user@host) would put this Mac's
  # login and host name into the key that goes to the PC and onto the screen.
  if ssh-keygen -q -t ed25519 -N "" -C "meshlink" -f "$KEY"; then
    done_ "created key $(tilde "$KEY") (no passphrase)"
    hint "anyone holding this file can log in to the PC as that account; keep it off cloud sync"
  else
    fail "could not create $(tilde "$KEY")"
    finish
  fi
fi
if [[ ! -f $KEY.pub ]]; then
  ssh-keygen -y -f "$KEY" >"$KEY.pub" || { fail "could not derive $(tilde "$KEY").pub"; finish; }
fi
PUBKEY=$(cat "$KEY.pub")

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
  block="# Added by scripts/setup.sh on $STAMP
Host $HOST_ALIAS
    HostName $ADDRESS
    User $WIN_USER
    IdentityFile $(tilde "$KEY")
    IdentitiesOnly yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 3
"
  # ssh takes the first value it finds for each option, so the entry has to
  # come before any Host or Match block (a "Host *" earlier would win). It
  # must also come after any top-level Include or option, which would
  # otherwise end up inside this entry.
  if [[ -f $CONFIG ]]; then
    cp -p "$CONFIG" "$CONFIG.bak-$STAMP"
    first=$(grep -niE '^[[:space:]]*(Host|Match)[[:space:]]' "$CONFIG" | head -1 | cut -d: -f1)
    tmp="$CONFIG.tmp-$STAMP"
    if [[ -n $first ]]; then
      { head -n $((first - 1)) "$CONFIG"; printf '%s\n' "$block"; tail -n +"$first" "$CONFIG"; } >"$tmp"
    else
      { cat "$CONFIG"; [[ -s $CONFIG ]] && echo; printf '%s' "$block"; } >"$tmp"
    fi
    # Keep the file itself (and its mode) by rewriting its content.
    cat "$tmp" >"$CONFIG" && rm -f "$tmp"
    done_ "added Host $HOST_ALIAS to $(tilde "$CONFIG") (backup: config.bak-$STAMP)"
  else
    printf '%s' "$block" >"$CONFIG"
    chmod 600 "$CONFIG"
    done_ "created $(tilde "$CONFIG") with Host $HOST_ALIAS"
  fi
fi

PORT=$(resolved port)
PORT=${PORT:-22}
KH_NAME=$ADDRESS
[[ $PORT != 22 ]] && KH_NAME="[$ADDRESS]:$PORT"

login() {
  ssh -F "$CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "$HOST_ALIAS" "echo setup-ok" 2>&1
}

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
known=$(ssh-keygen -F "$KH_NAME" -f "$KNOWN" 2>/dev/null | grep -v '^#')
if [[ -n $known ]] && [[ $(login) == *setup-ok* ]]; then
  ok "host key for $ADDRESS already trusted"
  ok "ssh $HOST_ALIAS logs in as $WIN_USER"
  hint "next: $CMD_CLIENT --host $HOST_ALIAS, then $CMD_DOCTOR"
  finish
fi

windows_step

scan=$(ssh-keyscan -T 10 -p "$PORT" -t ed25519 "$ADDRESS" 2>/dev/null | grep -v '^#')
if [[ -z $scan ]]; then
  fail "could not read the PC's host key at $ADDRESS:$PORT"
  hint "check that sshd runs on the PC and the address is right, then run this again"
  finish
fi
fp=$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)

if [[ -n $known ]]; then
  stored=$(printf '%s\n' "$known" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
  if printf '%s\n' "$stored" | grep -qxF "$fp"; then
    ok "host key for $ADDRESS matches known_hosts ($fp)"
  else
    fail "the PC's host key does not match the one in $(tilde "$KNOWN")"
    hint "if the PC was reinstalled or sshd re-created its keys, remove the old entry with: ssh-keygen -R '$KH_NAME'"
    hint "otherwise stop here: something else may be answering at $ADDRESS"
    finish
  fi
else
  echo "The PC at $ADDRESS presents this host key:"
  echo
  echo "  $fp (ED25519)"
  echo
  if [[ -n $EXPECT_FP ]]; then
    if [[ $EXPECT_FP != "$fp" ]]; then
      fail "host key $fp is not the expected $EXPECT_FP"
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
  printf '%s\n' "$scan" | sed "s/^[^ ]*/$KH_NAME/" >>"$KNOWN"
  chmod 600 "$KNOWN"
  done_ "trusted host key $fp for $ADDRESS"
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
