# Pairing protocol values: nonces, the commitment and the pairing code (SAS).
# The exact byte strings are specified in docs/pairing.md, and the Rhino plugin
# must produce the same values; tests/pairing-vectors.txt pins both. Source it;
# do not run it. bash 3.2 compatible; needs only od, tr, cut, awk, head and shasum.

PAIR_VERSION=1

# pair_nonce -- 16 random bytes as 32 lowercase hex digits.
pair_nonce() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# pair_key KEYLINE -- an OpenSSH public key reduced to "type base64": the
# comment differs between a .pub file and known_hosts, so it is never hashed.
pair_key() {
  printf '%s\n' "$1" | tr -d '\r' | awk '{print $1 " " $2; exit}'
}

pair_sha256() {
  shasum -a 256 | cut -d' ' -f1
}

# pair_commit HOSTKEY NONCE_W -- what the plugin sends before it learns the
# Mac's nonce.
pair_commit() {
  printf 'meshlink-pair-v1 commit\n%s\n%s\n' "$(pair_key "$1")" "$2" | pair_sha256
}

# pair_sas MACPUB HOSTKEY NONCE_M NONCE_W -- the six-digit code both screens
# show, as "123 456".
pair_sas() {
  local h n
  h=$(printf 'meshlink-pair-v1 sas\n%s\n%s\n%s\n%s\n' \
        "$(pair_key "$1")" "$(pair_key "$2")" "$3" "$4" | pair_sha256)
  n=$(printf '%06d' $((16#${h:0:8} % 1000000)))
  printf '%s %s\n' "${n:0:3}" "${n:3:3}"
}

# ------------------------------------------------------------- messages
# A message is "MESHLINK-PAIR 1" followed by "KEY value" lines. Everything
# read from the network is untrusted: callers check each value's format.

# pair_get FILE KEY -- the first value of KEY (empty if absent).
pair_get() {
  tr -d '\r' <"$1" | awk -v k="$2" '$1 == k { i = index($0, " "); print (i ? substr($0, i + 1) : ""); exit }'
}

# pair_get_all FILE KEY -- every value of KEY, one per line.
pair_get_all() {
  tr -d '\r' <"$1" | awk -v k="$2" '$1 == k { i = index($0, " "); print (i ? substr($0, i + 1) : "") }'
}

# pair_is_step FILE N KEY... -- true if FILE is a message for step N that
# carries every KEY.
pair_is_step() {
  local file=$1 step=$2 key
  shift 2
  [[ $(tr -d '\r' <"$file" | head -1) == "MESHLINK-PAIR $PAIR_VERSION" ]] || return 1
  [[ $(pair_get "$file" STEP) == "$step" ]] || return 1
  for key in "$@"; do
    tr -d '\r' <"$file" | awk -v k="$key" '$1 == k { found = 1 } END { exit !found }' || return 1
  done
}

# pair_text -- network text made safe for the terminal: control characters
# (escape sequences) removed, UTF-8 kept.
pair_text() {
  LC_ALL=C tr -d '\000-\037\177'
}
