#!/usr/bin/env bash
# Verification harness for the pairing protocol (docs/pairing.md).
#
# For now it covers scripts/lib/pairing.sh only: the commitment and pairing
# code must match tests/pairing-vectors.txt, which was generated with Python
# independently of the bash code. The functions run under /bin/bash, the
# macOS system bash 3.2.
#
# Scenarios:
#   V1  each vector: commitment and pairing code      -> as in the file
#   V2  nonces                                        -> 32 hex digits, not repeated
#
# Usage: tests/test-pair.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/pairing.sh"
VECTORS="$ROOT/tests/pairing-vectors.txt"

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

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
