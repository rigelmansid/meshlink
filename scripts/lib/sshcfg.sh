# The Mac-side SSH steps shared by setup.sh and, later, pairing: the key, the
# Host entry in ~/.ssh/config, and trusting the PC's host key. Pairing replaces
# only how the public key reaches the PC and how the host key is confirmed;
# these steps stay the same. Source after common.sh; do not run it.
#
# The caller sets SSH_DIR, CONFIG, KNOWN, STAMP, HOST_ALIAS and KEY, and, before
# add_host_entry and set_kh_name, ADDRESS and WIN_USER. Functions that can fail
# report it with fail and return 1; the caller decides whether to finish.
# bash 3.2 compatible.

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

# ensure_key -- reuses or creates $KEY and its .pub; sets PUBKEY.
ensure_key() {
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
      return 1
    fi
  fi
  if [[ ! -f $KEY.pub ]]; then
    ssh-keygen -y -f "$KEY" >"$KEY.pub" || { fail "could not derive $(tilde "$KEY").pub"; return 1; }
  fi
  PUBKEY=$(cat "$KEY.pub")
}

# add_host_entry -- adds Host $HOST_ALIAS for $ADDRESS and $WIN_USER. The caller
# has checked has_alias; an existing entry is never changed.
add_host_entry() {
  local block first tmp
  block="# Added by scripts/$PROG.sh on $STAMP
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
}

# set_kh_name -- sets PORT and KH_NAME, the name known_hosts files the PC under.
set_kh_name() {
  PORT=$(resolved port)
  PORT=${PORT:-22}
  KH_NAME=$ADDRESS
  [[ $PORT != 22 ]] && KH_NAME="[$ADDRESS]:$PORT"
  return 0
}

login() {
  ssh -F "$CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "$HOST_ALIAS" "echo setup-ok" 2>&1
}

# known_entry -- sets KNOWN_ENTRY to what known_hosts holds for $KH_NAME.
known_entry() {
  KNOWN_ENTRY=$(ssh-keygen -F "$KH_NAME" -f "$KNOWN" 2>/dev/null | grep -v '^#')
}

# scan_host_key -- reads the PC's ED25519 host key into SCAN and its
# fingerprint into FP.
scan_host_key() {
  SCAN=$(ssh-keyscan -T 10 -p "$PORT" -t ed25519 "$ADDRESS" 2>/dev/null | grep -v '^#')
  if [[ -z $SCAN ]]; then
    fail "could not read the PC's host key at $ADDRESS:$PORT"
    hint "check that sshd runs on the PC and the address is right, then run this again"
    return 1
  fi
  FP=$(printf '%s\n' "$SCAN" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}' | head -1)
}

# check_known_host_key -- with KNOWN_ENTRY set: returns 0 if it holds $FP,
# otherwise reports the mismatch and returns 1.
check_known_host_key() {
  local stored
  stored=$(printf '%s\n' "$KNOWN_ENTRY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
  if printf '%s\n' "$stored" | grep -qxF "$FP"; then
    ok "host key for $ADDRESS matches known_hosts ($FP)"
    return 0
  fi
  fail "the PC's host key does not match the one in $(tilde "$KNOWN")"
  hint "if the PC was reinstalled or sshd re-created its keys, remove the old entry with: ssh-keygen -R '$KH_NAME'"
  hint "otherwise stop here: something else may be answering at $ADDRESS"
  return 1
}

# trust_host_key -- adds $SCAN to known_hosts under $KH_NAME. Only after the
# caller has confirmed $FP.
trust_host_key() {
  printf '%s\n' "$SCAN" | sed "s/^[^ ]*/$KH_NAME/" >>"$KNOWN"
  chmod 600 "$KNOWN"
  done_ "trusted host key $FP for $ADDRESS"
}
