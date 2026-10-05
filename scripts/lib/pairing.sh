# Pairing protocol values: nonces, the commitment and the pairing code (SAS).
# The exact byte strings are specified in docs/pairing.md, and the Rhino plugin
# must produce the same values; tests/pairing-vectors.txt pins both. Source it;
# do not run it. bash 3.2 compatible; needs only od, tr, cut and shasum.

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
