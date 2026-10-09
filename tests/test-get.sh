#!/usr/bin/env bash
# Verification harness for get.sh, the one-line installer (D-32).
#
# Builds a release with scripts/package.sh and serves it, with a releases
# feed, through a fake curl(1) prepended to PATH, so nothing goes to the
# network. Each scenario runs get.sh in its own temporary home.
#
#   G1  fresh install: newest release from the feed, PATH line added once
#   G2  run again: upgrade in place, no second PATH line
#   G3  ~/.local/bin already in PATH: startup file left alone
#   G4  MESHLINK_NO_MODIFY_PATH=1, and a shell other than zsh or bash
#   G5  bash: the line goes to ~/.bash_profile
#   G6  checksum mismatch: nothing installed
#   G7  feed unreachable: clear failure; MESHLINK_VERSION still installs
#   G8  a version that is not one: refused before any download
#   G9  a script cut short: runs nothing
#
# Usage: tests/test-get.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GET="$ROOT/get.sh"
VERSION=$(cat "$ROOT/VERSION")
NAME="meshlink-$VERSION.tar.gz"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meshlink-get-test.XXXXXX")"
FAKE_BIN="$WORK/bin"
REL="$WORK/rel/v$VERSION"
mkdir -p "$FAKE_BIN" "$REL" "$WORK/tmp"

pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass+1)); }
bad() { echo "  FAIL : $1"; fail=$((fail+1)); }
has() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
hasnt() { grep -qF -- "$2" "$1" && bad "$3 (found [$2] in $1)" || ok "$3"; }

# ------------------------------------------------------------- the release
# Leave dist/ as found: remove only files this run created there.
pre_existing=no
[[ -e $ROOT/dist/$NAME ]] && pre_existing=yes
"$ROOT/scripts/package.sh" >"$WORK/pkg.log" 2>&1 || { echo "package.sh failed"; cat "$WORK/pkg.log"; exit 1; }
cp "$ROOT/dist/$NAME" "$ROOT/dist/$NAME.sha256" "$REL/"
if [[ $pre_existing == no ]]; then
  rm -f "$ROOT/dist/$NAME" "$ROOT/dist/$NAME.sha256"
  rmdir "$ROOT/dist" 2>/dev/null
fi
trap 'rm -rf "$WORK"' EXIT

# The real feed's shape: the feed's own id first, then entries newest first.
cat >"$WORK/feed.atom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
  <id>tag:github.com,2008:https://github.com/rigelmansid/meshlink/releases</id>
  <entry>
    <id>tag:github.com,2008:Repository/1/v$VERSION</id>
    <title>meshlink $VERSION</title>
  </entry>
  <entry>
    <id>tag:github.com,2008:Repository/1/v0.1.0-dev</id>
    <title>meshlink 0.1.0-dev</title>
  </entry>
</feed>
EOF

cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# fake curl(1): -o FILE and one URL; serves the feed and $FAKE_REL/<path>.
out=""; url=""
while (($#)); do
  case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "$url" >>"$FAKE_LOG"
case $url in
  https://feed.test/*) [[ ${FAKE_FEED:-up} == up ]] || exit 7; src=$FAKE_FEED_FILE ;;
  https://dl.test/*) src="$FAKE_REL/${url#https://dl.test/}" ;;
  *) exit 6 ;;
esac
[[ -f $src ]] || exit 22
if [[ -n $out ]]; then cp "$src" "$out"; else cat "$src"; fi
FAKE
chmod +x "$FAKE_BIN/curl"

# run_get LABEL [VAR=value...] -- runs get.sh in a fresh home ($H), output in
# $WORK/LABEL.log, exit code in rc. Extra assignments go into the environment.
run_get() {
  local label=$1; shift
  H="$WORK/home-$label"
  mkdir -p "$H"
  : >"$WORK/$label.urls"
  env -i HOME="$H" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh \
      TMPDIR="$WORK/tmp" FAKE_LOG="$WORK/$label.urls" FAKE_REL="$WORK/rel" \
      FAKE_FEED_FILE="$WORK/feed.atom" \
      MESHLINK_FEED=https://feed.test/releases.atom MESHLINK_DOWNLOAD=https://dl.test \
      "$@" bash "$GET" >"$WORK/$label.log" 2>&1
  rc=$?
}
again() { # run get.sh again in the same home
  local label=$1; shift
  env -i HOME="$H" PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh \
      TMPDIR="$WORK/tmp" FAKE_LOG="$WORK/$label.urls" FAKE_REL="$WORK/rel" \
      FAKE_FEED_FILE="$WORK/feed.atom" \
      MESHLINK_FEED=https://feed.test/releases.atom MESHLINK_DOWNLOAD=https://dl.test \
      "$@" bash "$GET" >"$WORK/$label.log" 2>&1
  rc=$?
}
installed() { [[ $("$H/.local/bin/meshlink" version 2>/dev/null) == "meshlink $VERSION" ]]; }
tmp_clean() { [[ -z $(ls -A "$WORK/tmp") ]]; }
line='export PATH="$HOME/.local/bin:$PATH"'

echo "G1 fresh install"
run_get g1
[[ $rc -eq 0 ]] && ok "exits 0" || bad "exit code $rc (see $WORK/g1.log)"
installed && ok "meshlink $VERSION installed" || bad "meshlink not installed"
head -1 "$WORK/g1.urls" | grep -q '^https://feed.test/' && ok "asks the feed first" || bad "did not read the feed first"
has "$WORK/g1.urls" "https://dl.test/v$VERSION/$NAME" "downloads the newest release"
[[ $(grep -cxF "$line" "$H/.zshrc" 2>/dev/null) -eq 1 ]] && ok "PATH line added to ~/.zshrc" || bad "PATH line not in ~/.zshrc once"
has "$WORK/g1.log" "open a new terminal window" "says to open a new terminal"
hasnt "$WORK/g1.log" "is not in your PATH" "no PATH advice from install.sh as well"
tmp_clean && ok "temporary files removed" || bad "temporary files left in $WORK/tmp"

echo "G2 run again"
again g2
[[ $rc -eq 0 ]] && ok "second run exits 0" || bad "second run exit code $rc"
has "$WORK/g2.log" "$VERSION -> $VERSION installed" "upgrades in place"
[[ $(grep -cxF "$line" "$H/.zshrc") -eq 1 ]] && ok "still one PATH line" || bad "PATH line added twice"

echo "G3 ~/.local/bin already in PATH"
H="$WORK/home-g3"; mkdir -p "$H"
env -i HOME="$H" PATH="$H/.local/bin:$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" SHELL=/bin/zsh \
    TMPDIR="$WORK/tmp" FAKE_LOG="$WORK/g3.urls" FAKE_REL="$WORK/rel" FAKE_FEED_FILE="$WORK/feed.atom" \
    MESHLINK_FEED=https://feed.test/releases.atom MESHLINK_DOWNLOAD=https://dl.test \
    bash "$GET" >"$WORK/g3.log" 2>&1
rc=$?
[[ $rc -eq 0 ]] && installed && ok "installs" || bad "exit code $rc"
[[ ! -e $H/.zshrc ]] && ok "~/.zshrc not created" || bad "~/.zshrc written although PATH had the directory"
hasnt "$WORK/g3.log" "new terminal" "no new-terminal advice needed"

echo "G4 MESHLINK_NO_MODIFY_PATH=1, and another shell"
run_get g4 MESHLINK_NO_MODIFY_PATH=1
[[ $rc -eq 0 ]] && installed && ok "installs" || bad "exit code $rc"
[[ ! -e $H/.zshrc ]] && ok "~/.zshrc left alone" || bad "~/.zshrc written"
has "$WORK/g4.log" "$line" "prints the line to add"
run_get g4f SHELL=/usr/local/bin/fish
[[ ! -e $H/.zshrc && ! -e $H/.bash_profile ]] && ok "fish: no startup file written" || bad "fish: a startup file was written"
has "$WORK/g4f.log" "$line" "fish: prints the line to add"

echo "G5 bash"
run_get g5 SHELL=/bin/bash
[[ $(grep -cxF "$line" "$H/.bash_profile" 2>/dev/null) -eq 1 ]] && ok "PATH line in ~/.bash_profile" || bad "PATH line not in ~/.bash_profile"
[[ ! -e $H/.zshrc ]] && ok "~/.zshrc untouched" || bad "~/.zshrc written for bash"

echo "G6 checksum mismatch"
cp "$REL/$NAME.sha256" "$WORK/sha.keep"
awk '{ c = substr($0, 1, 1); print (c == "0" ? "1" : "0") substr($0, 2) }' "$WORK/sha.keep" >"$REL/$NAME.sha256"
run_get g6
cp "$WORK/sha.keep" "$REL/$NAME.sha256"
[[ $rc -ne 0 ]] && ok "fails" || bad "exit code 0 on a bad checksum"
has "$WORK/g6.log" "does not match its SHA-256 file" "says why"
[[ ! -e $H/.local/share/meshlink && ! -e $H/.zshrc ]] && ok "nothing installed or written" || bad "something was installed"
tmp_clean && ok "temporary files removed" || bad "temporary files left"

echo "G7 feed unreachable"
run_get g7 FAKE_FEED=down
[[ $rc -ne 0 ]] && ok "fails" || bad "exit code 0 without the feed"
has "$WORK/g7.log" "set MESHLINK_VERSION" "suggests MESHLINK_VERSION"
[[ $(wc -l <"$WORK/g7.urls") -eq 1 ]] && ok "no download attempted" || bad "downloaded without a version"
run_get g7v FAKE_FEED=down MESHLINK_VERSION="v$VERSION"
[[ $rc -eq 0 ]] && installed && ok "MESHLINK_VERSION installs without the feed" || bad "MESHLINK_VERSION: exit code $rc"
hasnt "$WORK/g7v.urls" "feed.test" "feed not asked when the version is given"

echo "G8 not a version"
run_get g8 'MESHLINK_VERSION=1.0;touch x'
[[ $rc -ne 0 ]] && ok "refused" || bad "accepted a bad version"
[[ ! -s $WORK/g8.urls ]] && ok "nothing downloaded" || bad "downloaded for a bad version"

echo "G9 a script cut short"
H="$WORK/home-g9"; mkdir -p "$H"
: >"$WORK/g9.urls"
head -n "$(($(grep -n '^  tmp=' "$GET" | cut -d: -f1) + 1))" "$GET" |
  env -i HOME="$H" PATH="$FAKE_BIN:/usr/bin:/bin" SHELL=/bin/zsh FAKE_LOG="$WORK/g9.urls" \
      FAKE_REL="$WORK/rel" FAKE_FEED_FILE="$WORK/feed.atom" \
      MESHLINK_FEED=https://feed.test/releases.atom MESHLINK_DOWNLOAD=https://dl.test bash >"$WORK/g9.log" 2>&1
[[ ! -s $WORK/g9.urls && ! -e $H/.local ]] && ok "runs nothing" || bad "a partial script did something"

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
